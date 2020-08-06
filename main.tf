#
# Nomad ASG termination lifecycle hook resources
#
resource "aws_iam_role" "cloudwatch_event_handler" {
  name_prefix        = "nomad-drain-lambda-"
  assume_role_policy = data.aws_iam_policy_document.events_assume_role.json
  tags               = var.resource_tags
}

data "aws_iam_policy_document" "events_assume_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
      ]
    }
  }
}

# Create a UUID to send as part of the lifecycle hook lambda. This allows us to match the events in CloudWatch
# regardless of what the ASG is named.
resource "random_uuid" "drain_lambda" {}

# Enable terminate lifecycle hooks for the Nomad clients ASG
resource "aws_autoscaling_lifecycle_hook" "nomad_clients_draining" {
  name                   = "nomad-client-draining"
  autoscaling_group_name = var.asg_name
  default_result         = "CONTINUE"
  heartbeat_timeout      = 600
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  notification_metadata = jsonencode({
    drain_lambda_uuid = random_uuid.drain_lambda.result
  })
}

#
# CloudWatch-related resources to propagate Nomad ASG termination lifecycle events into
# the associated state machine.
#
resource "aws_cloudwatch_event_rule" "nomad_asg_terminate_lifecycle_event" {
  name_prefix = "nomad-client-drainer-"
  description = "Capture nomad instance terminate lifecycle actions"

  event_pattern = <<-PATTERN
    {
      "source": [ "aws.autoscaling" ],
      "detail-type": [ "EC2 Instance-terminate Lifecycle Action" ],
      "detail": {
        "NotificationMetadata": {
          "drain_lambda_uuid": ["${random_uuid.drain_lambda.result}"]
        },
        "LifecycleHookName": [
            "${aws_autoscaling_lifecycle_hook.nomad_clients_draining.name}"
        ]
      }
    }
    PATTERN
}

data "aws_iam_policy_document" "nomad_asg_terminate_lifecycle_event" {
  statement {
    sid = "InvokeNomadLifecycleHandlerStateMachine"

    actions = [
      "states:StartExecution",
    ]

    resources = [
      aws_sfn_state_machine.nomad_asg_lifecycle_state_machine.id
    ]
  }
}

resource "aws_iam_role_policy" "nomad_asg_terminate_lifecycle_event" {
  name   = "InvokeNomadAutoscaleStateMachine"
  role   = aws_iam_role.cloudwatch_event_handler.id
  policy = data.aws_iam_policy_document.nomad_asg_terminate_lifecycle_event.json
}

resource "aws_cloudwatch_event_target" "nomad_asg_terminate_lifecycle_event" {
  rule     = aws_cloudwatch_event_rule.nomad_asg_terminate_lifecycle_event.name
  arn      = aws_sfn_state_machine.nomad_asg_lifecycle_state_machine.id
  role_arn = aws_iam_role.cloudwatch_event_handler.arn
}


#
# State machine / step function-specific resources
#
data "aws_iam_policy_document" "nomad_asg_lifecycle_state_machine_assume_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "states.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "nomad_asg_lifecycle_state_machine" {
  name               = "NomadAutoscaleLifecycleStateMachine"
  description        = "Execution role for Nomad auto scaling-related state machines"
  assume_role_policy = data.aws_iam_policy_document.nomad_asg_lifecycle_state_machine_assume_role.json
}

# Policy to allow the state machine itself to invoke the lambda containing the logic that
# handles responding to Nomad instance termination notification.
data "aws_iam_policy_document" "nomad_asg_lifecycle_state_machine" {
  statement {
    sid = "InvokeNomadLifecycleHandlerLambda"

    actions = [
      "lambda:InvokeFunction",
    ]

    resources = [
      aws_lambda_function.nomad_asg_lifecycle_handler.arn
    ]
  }
}

resource "aws_iam_role_policy" "nomad_asg_lifecycle_state_machine" {
  name   = "InvokeNomadAutoscaleLifecycle"
  role   = aws_iam_role.nomad_asg_lifecycle_state_machine.id
  policy = data.aws_iam_policy_document.nomad_asg_lifecycle_state_machine.json
}

locals {
  state_machine_definition = {
    Comment = "Responds to nomad ASG termination lifecycle events and gracefully drain allocations from nodes before termination."
    StartAt = "Handle ASG Lifecycle Event"
    States = {
      "Handle ASG Lifecycle Event" = {
        Type       = "Task"
        Resource   = "${aws_lambda_function.nomad_asg_lifecycle_handler.arn}"
        ResultPath = "$"
        Next       = "Node Ready for Termination?"
        Retry = [
          {
            ErrorEquals = [
              "States.TaskFailed",
            ]
            IntervalSeconds = 30
            MaxAttempts     = 3
            BackoffRate     = 3.0
          }
        ]
      }
      "Node Ready for Termination?" = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.ready_for_termination"
            BooleanEquals = true
            Next          = "ASG Lifecycle Event Handed Successfully"
          },
          {
            Variable      = "$.max_wait_time_exceeded"
            BooleanEquals = true
            Next          = "Max Node Drain Wait Time Exceeded"
          }
        ],
        Default = "Node Still Draining - Wait 3 Minutes"
      },
      "Node Still Draining - Wait 3 Minutes" = {
        Type    = "Wait"
        Seconds = 180
        Next    = "Handle ASG Lifecycle Event"
      },
      "ASG Lifecycle Event Handed Successfully" = {
        Type = "Succeed"
      },
      "Max Node Drain Wait Time Exceeded" = {
        Type  = "Fail"
        Cause = "Max time to wait for node to drain exceeded"
      }
    }
  }
}

resource "aws_sfn_state_machine" "nomad_asg_lifecycle_state_machine" {
  name       = "NomadAutoscaleTerminationLifecycle"
  role_arn   = aws_iam_role.nomad_asg_lifecycle_state_machine.arn
  definition = jsonencode(local.state_machine_definition)
  tags       = var.resource_tags
}


#
# Lambda-specific resources (security group, IAM, etc.)
#
data "aws_iam_policy_document" "nomad_asg_lifecycle_handler_assume_role" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "nomad_asg_lifecycle_handler" {
  name_prefix        = "nomad-asg-drain-lambda-"
  description        = "Role used by lambda when responding to nomad auto scaling lifecycle hook events."
  assume_role_policy = data.aws_iam_policy_document.nomad_asg_lifecycle_handler_assume_role.json
}

data "aws_iam_policy_document" "nomad_asg_lifecycle_handler" {
  statement {
    sid = "AsgLifecycleCompleteAndHeartBeat"

    actions = [
      "autoscaling:RecordLifecycleActionHeartbeat",
      "autoscaling:CompleteLifecycleAction",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/Name"

      values = [
        var.asg_name,
      ]
    }
  }

  statement {
    sid = "DescribeNomadBuilderEc2Instances"

    actions = [
      "ec2:DescribeInstances",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "nomad_asg_lifecycle_handler_policy" {
  name   = "NomadAsgLifecyclePolicy"
  role   = aws_iam_role.nomad_asg_lifecycle_handler.id
  policy = data.aws_iam_policy_document.nomad_asg_lifecycle_handler.json
}

resource "aws_iam_role_policy_attachment" "nomad_asg_lifecycle_handler_vpc_access" {
  role       = aws_iam_role.nomad_asg_lifecycle_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "nomad_asg_lifecycle_handler" {
  name_prefix = "nomad-asg-drain-lambda-"
  description = "Lambda that gracefully drains nomad nodes upon terminating lifecycle events from their ASG"
  vpc_id      = var.vpc_id

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}


data "pypi_requirements_file" "nomad_asg_lifecycle_handler" {
  requirements_file = "${path.module}/files/nomad_asg_lifecycle_lambda/requirements.txt"
  output_dir        = "${path.module}/files/nomad_asg_lifecycle_lambda"
}

data "archive_file" "nomad_asg_lifecycle_handler" {
  type        = "zip"
  source_dir  = "${path.module}/files/nomad_asg_lifecycle_lambda"
  output_path = "${path.module}/files/nomad_asg_lifecycle_lambda.zip"

  depends_on = [
    data.pypi_requirements_file.nomad_asg_lifecycle_handler,
  ]
}

resource "aws_lambda_function" "nomad_asg_lifecycle_handler" {
  filename         = data.archive_file.nomad_asg_lifecycle_handler.output_path
  source_code_hash = data.archive_file.nomad_asg_lifecycle_handler.output_base64sha256
  function_name    = "nomad_asg_lifecycle_handler"
  role             = aws_iam_role.nomad_asg_lifecycle_handler.arn
  handler          = "main.handle_asg_lifecycle_event"
  timeout          = "60"
  runtime          = "python3.8"

  tags = var.resource_tags

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.nomad_asg_lifecycle_handler.id]
  }

  environment {
    variables = {
      LOG_LEVEL                   = "DEBUG"
      NODE_DRAIN_DEADLINE_MINUTES = 120
      MAX_WAIT_TIME_MINUTES       = 125
      NOMAD_ADDR                  = var.nomad_address
      NODE_NAME_FORMAT            = "nomad-client-{instance_id}"
    }
  }
}
