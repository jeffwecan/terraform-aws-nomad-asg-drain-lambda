#!/usr/bin/env python
"""Lambda function that responds to nomad ASG lifecycle hook notifications.

Gracefully drains nomad nodes before notifying the ASG to complete termination.
"""

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Optional, TYPE_CHECKING

import boto3
from dateutil.parser import parse
from nomad import Nomad

if TYPE_CHECKING:
    from nomad.api.exceptions import BaseNomadException

logger = logging.getLogger()
logger.setLevel(getattr(logging, os.getenv('LOG_LEVEL', 'INFO')))

# The Nomad API takes its node drain deadline parameter in nanoseconds
NANO_SECONDS = 10 ** 9
# We default to a node drain deadline of two hours
NODE_DRAIN_DURATION_NS = int(os.getenv('NODE_DRAIN_DEADLINE_MINUTES', 120 * 60)) * NANO_SECONDS

# Maximum amount of time for a node to meet our termination conditions
# before we go ahead and terminate it regardless
MAX_WAIT_TIME_MINUTES = int(os.getenv('MAX_WAIT_TIME_MINUTES', 125))


def get_ec2_instance_private_ip(instance_id: str) -> str:
    """Lookup a EC2 instance by ID and retrieve its private IP.

    Args:
        instance_id (str): EC2 instance ID.

    Returns:
        str: The private IP associated with the specified EC2 instance.
    """
    ec2 = boto3.resource('ec2')
    instance = ec2.Instance(instance_id)
    node_ip = instance.private_ip_address
    logger.info(f'Instance {instance_id} private IP address: {node_ip}')
    return node_ip


def get_node_id_by_instance_id(nomad_api: Nomad, instance_id: str) -> str:
    """Retrieve the Nomad node ID associated with an EC2 instance ID via the Nomad API.

    Args:
        nomad_api (Nomad): An instantiated Nomad API client.
        instance_id (str): EC2 instance ID.

    Raises:
        Exception: If no Nomad node is found to match the provided EC2 instance ID.
        BaseNomadException: If an unexpected status code is returned from the Nomad API.

    Returns:
        str: The relevant Nomad node ID.
    """
    nodes = nomad_api.nodes.get_nodes()
    logger.debug(f'get_nodes() response: {nodes}')
    node_name = os.environ['NODE_NAME_FORMAT'].format(instance_id=instance_id)

    for node in nodes:
        if node['Name'] == node_name:
            logger.info(f'Found node for instance ID {node_name}, node ID: {node["ID"]}')
            node_id = node["ID"]
            break
    else:
        raise Exception(f'no matching node found for instance ID: {node_name}')

    return node_id


def ensure_node_is_draining(nomad_api: Nomad, node_id: str) -> Optional[dict]:
    """Ensure the specified Nomad node is draining.

    Args:
        nomad_api (Nomad): An instantiated Nomad API client.
        node_id (str): The ID of the Nomad node to drain allocations from.

    Returns:
        Optional[dict]: When Node hasn't started draining, returns the response of the drain node
        request, otherwise None.
    """
    node = nomad_api.node.get_node(node_id)
    eligible_resp = nomad_api.node.eligible_node(
        id=node_id,
        ineligible=True,
    )
    logger.info(f'Marking node as ineligible response: {eligible_resp}')

    if not node['Drain']:
        logger.info(f'Draining jobs from node ID {node_id}, drain duration: '
                    f'{NODE_DRAIN_DURATION_NS // 60 // NANO_SECONDS} (minutes)')
        drain_resp = nomad_api.node.drain_node_with_spec(
            id=node_id,
            drain_spec={"Duration": NODE_DRAIN_DURATION_NS, 'MarkEligible': False},
        )
        logger.debug(f'Drain node response: {drain_resp}')
        return drain_resp
    else:
        logger.info(f'Node ID {node_id} is already draining jobs...')


def is_node_ready_for_termination(nomad_api: Nomad, node_id: str) -> bool:
    """Query a Nomad node's status to determine if its ready to be terminated or not.

    The two criteria used for terminability are:
        * how many allocations are running on the node? (must be zero before we can safely terminate)
        * is the node marked eligible for new allocations? (must be ineligible so new allocations aren't added)

    Args:
        nomad_api (Nomad): An instantiated Nomad API client.
        node_id (str): The ID of the Nomad node under consideration.
    Returns:
        bool: True if the node is ready for termination, False otherwise.
    """
    node = nomad_api.node.get_node(node_id)

    allocations = nomad_api.node.get_allocations(node_id)
    pending_or_running_allocs = [a for a in allocations if a['ClientStatus'] in ['pending', 'running']]

    if pending_or_running_allocs:
        logger.info(f'Pending and running allocations for node {node_id}:')
    for alloc in pending_or_running_allocs:
        create_datetime = datetime.fromtimestamp(alloc['CreateTime'] / NANO_SECONDS)
        alloc_log_output = {
            'allocation_id': alloc['ID'],
            'client_status': alloc['ClientStatus'],
            'create_time': create_datetime.strftime('%c'),
            'elapsed_time': str(datetime.now() - create_datetime),
            'job_id': alloc['Job'].get('ID'),
        }
        logger.info(alloc_log_output)

    num_remaining_allocs = len(pending_or_running_allocs)
    logger.info(f'Number of remaining allocations for node id {node_id}: {num_remaining_allocs}')

    eligible_for_scheduling = node['SchedulingEligibility'] == 'eligible'
    logger.info(f'Scheduling eligibility for node id {node_id}: {eligible_for_scheduling}')

    ready_for_termination = num_remaining_allocs == 0 and not eligible_for_scheduling
    logger.info(f'Node ready for termination?: {ready_for_termination}')

    return ready_for_termination


def is_max_wait_time_exceeded(event_time: str) -> bool:
    """Determine if the maximum overall lifecycle hook handling exceeds our threshold.

    In the event we can't successfully drain a node (for whatever reason) we eventually want to bomb
    out and terminate the node regardless.

    Args:
        event_time (str): The timestamp string provided in the initial ASG lifecycle hook message.

    Returns:
        bool: True if maximum wait time is exceeded, False otherwise.
    """
    max_wait_time = parse(event_time) + timedelta(minutes=MAX_WAIT_TIME_MINUTES)
    current_time = datetime.now(timezone.utc)
    logger.info(f'Max wait time for node drain is {MAX_WAIT_TIME_MINUTES} minutes / {max_wait_time}')
    logger.info(f'Current time: {current_time}')

    max_wait_time_exceeded = current_time > max_wait_time
    logger.info(f'Max wait time exceeded?: {max_wait_time_exceeded}')

    return max_wait_time_exceeded


def send_asg_lifecycle_notifications(event_detail: dict, complete_action: bool) -> dict:
    """Send a request to the ASG service to complete a lifecycle action or to keep the associated instance's status pending.

    Args:
        event_detail (dict): The details (e.g., lifecycle action token) associated with the lifecycle hook event
        being processed.
        complete_action (bool): If True, complete the lifecycle action (e.g., allow the ASG to finish terminating the
        instance). If False, send an "action heartbeat" so the ASG continues waiting for our response.

    Returns:
        dict: The response of the complete lifecycle action or record lifecycle action heartbeat request.
    """
    asg_client = boto3.client('autoscaling')
    if complete_action:
        logger.info('Node ready for termination and/or max wait time exceeded, sending ASG lifecycle compeletion...')
        response = asg_client.complete_lifecycle_action(
            LifecycleHookName=event_detail['LifecycleHookName'],
            AutoScalingGroupName=event_detail['AutoScalingGroupName'],
            LifecycleActionToken=event_detail['LifecycleActionToken'],
            LifecycleActionResult='CONTINUE',
            InstanceId=event_detail['EC2InstanceId'],
        )
        logger.debug(f'complete_lifecycle_action response: {response}')
        return response

    logger.info('Node not currently ready for termination, sending ASG lifecycle action heartbeat...')
    response = asg_client.record_lifecycle_action_heartbeat(
        LifecycleHookName=event_detail['LifecycleHookName'],
        AutoScalingGroupName=event_detail['AutoScalingGroupName'],
        LifecycleActionToken=event_detail['LifecycleActionToken'],
        InstanceId=event_detail['EC2InstanceId'],
    )
    logger.debug(f'record_lifecycle_action_heartbeat response: {response}')
    return response


def handle_asg_lifecycle_event(event, context) -> dict:
    """Handle Nomad node ASG lifecycle events.

    Note: Currently only intended to handle "terminate lifecycle" actions.

    Args:
        event: ASG Lifecycle event data provided by AWS.
        context: Runtime information for the lambda.

    Raises:
        NotImplementedError: Raised when we receive an event with a "detail-type" other than:
        "EC2 Instance-terminate Lifecycle Action".

    Returns:
        dict: Includes both relevant details from the original event (so that this function can call itself with its
        own outputs) as well as information about any actions taken (e.g., if the instance was ready for termination, etc.)
    """
    if event['detail-type'] != 'EC2 Instance-terminate Lifecycle Action':
        raise NotImplementedError('Only EC2 instance terminate lifecycle notifications currently supported')

    # Map the terminating EC2 instance's ID to the corresponding nomad node ID
    nomad_api = Nomad(
        host=os.environ['NOMAD_ADDR'],
        timeout=60,
    )
    node_id = get_node_id_by_instance_id(
        nomad_api=nomad_api,
        instance_id=event['detail']['EC2InstanceId'],
    )

    # Ensure the node associated with the terminating instance is draining jobs
    ensure_node_is_draining(
        nomad_api=nomad_api,
        node_id=node_id,
    )

    # Check to see if we're ready to terminate the associated nomad node.
    ready_for_termination = is_node_ready_for_termination(
        nomad_api=nomad_api,
        node_id=node_id,
    )
    max_wait_time_exceeded = is_max_wait_time_exceeded(event['time'])
    send_asg_lifecycle_notifications(
        event_detail=event['detail'],
        complete_action=ready_for_termination or max_wait_time_exceeded,
    )

    return {
        'detail-type': event['detail-type'],
        'time': event['time'],
        'detail': event['detail'],
        'ready_for_termination': ready_for_termination,
        'max_wait_time_exceeded': max_wait_time_exceeded,
    }
