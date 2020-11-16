variable "asg_name" {
  type        = string
  description = "Name of the AWS ASG housing nomad client instances that should be drained before completing the ASG termination lifecycle hook."
}

variable "nomad_address" {
  type        = string
  description = "The address (protocol plus domain name) to send nomad API request to."
}

variable "resource_tags" {
  type        = map(string)
  description = "Map of tags to apply to all relevant AWS resources."
  default     = {}
}

variable "subnet_ids" {
  description = "A list of subnet IDs that the lambda will be placed within."
  type        = list(string)
  default     = []
}

variable "target_group_arns" {
  description = "An optional list of aws_alb_target_group ARNs that launching instances placed in / terminating instances removed from."
  type        = list(string)
  default     = []
}

variable "vpc_id" {
  type        = string
  description = "The ID of the VPC housing the associated nomad client ASG."
}
