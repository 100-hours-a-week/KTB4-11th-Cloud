variable "dev_telemetry_enabled" {
  description = "Connect the development App EC2 and optionally its AI EC2 to central monitoring"
  type        = bool
  default     = false

  validation {
    condition     = !var.dev_telemetry_enabled || var.plg_tempo_enabled
    error_message = "Development collection requires plg_tempo_enabled=true."
  }
}

variable "dev_vpc_peering_connection_id" {
  description = "Existing active same-account/region peering ID; empty creates a dedicated connection"
  type        = string
  default     = ""

  validation {
    condition     = var.dev_vpc_peering_connection_id == "" || can(regex("^pcx-[0-9a-f]+$", var.dev_vpc_peering_connection_id))
    error_message = "Use an existing pcx- ID or an empty string."
  }
}

data "terraform_remote_state" "development" {
  count   = var.dev_telemetry_enabled ? 1 : 0
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "test-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  dev_host = var.dev_telemetry_enabled ? data.terraform_remote_state.development[0].outputs : null
  dev_peering_id = !var.dev_telemetry_enabled ? null : (
    var.dev_vpc_peering_connection_id != "" ? data.aws_vpc_peering_connection.development[0].id : aws_vpc_peering_connection.development[0].id
  )
}

data "aws_vpc_peering_connection" "development" {
  count = var.dev_telemetry_enabled && var.dev_vpc_peering_connection_id != "" ? 1 : 0
  id    = var.dev_vpc_peering_connection_id

  lifecycle {
    postcondition {
      condition = self.status == "active" && toset([self.vpc_id, self.peer_vpc_id]) == toset([
        data.terraform_remote_state.shared.outputs.vpc_id, local.dev_host.vpc_id,
      ])
      error_message = "The existing peering must be active and connect the development and monitoring VPCs."
    }
  }
}

resource "aws_vpc_peering_connection" "development" {
  count       = var.dev_telemetry_enabled && var.dev_vpc_peering_connection_id == "" ? 1 : 0
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
  peer_vpc_id = local.dev_host.vpc_id
  auto_accept = true
  tags        = { Name = "stockspoon-dev-to-telemetry" }
}

data "aws_route_table" "development" {
  count     = var.dev_telemetry_enabled ? 1 : 0
  subnet_id = local.dev_host.public_subnet_id
}

data "aws_route_table" "telemetry" {
  count     = var.dev_telemetry_enabled ? 1 : 0
  subnet_id = data.aws_subnet.telemetry[0].id
}

# Keep host-specific routes across the peering. The AI host's return route
# is managed separately in ai_agents.tf; no whole-VPC route is required.
resource "aws_route" "development_to_telemetry" {
  count                     = var.dev_telemetry_enabled ? 1 : 0
  route_table_id            = data.aws_route_table.development[0].id
  destination_cidr_block    = "${aws_instance.telemetry[0].private_ip}/32"
  vpc_peering_connection_id = local.dev_peering_id
}

resource "aws_route" "telemetry_to_development" {
  count                     = var.dev_telemetry_enabled ? 1 : 0
  route_table_id            = data.aws_route_table.telemetry[0].id
  destination_cidr_block    = "${local.dev_host.dev_app_private_ip}/32"
  vpc_peering_connection_id = local.dev_peering_id
}

resource "aws_vpc_security_group_ingress_rule" "development_telemetry" {
  for_each = var.dev_telemetry_enabled ? {
    loki       = 3100
    prometheus = 9090
    traces     = 4318
  } : {}
  security_group_id            = aws_security_group.telemetry[0].id
  referenced_security_group_id = local.dev_host.dev_app_security_group_id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "Development application to telemetry ${each.key}"
  depends_on                   = [aws_vpc_peering_connection.development]
}

output "development_telemetry" {
  description = "Private development agent target and endpoints; no credentials"
  value = var.dev_telemetry_enabled ? {
    instance_id          = local.dev_host.dev_app_instance_id
    private_ip           = local.dev_host.dev_app_private_ip
    environment          = "dev"
    cluster              = "stockspoon-v2-dev"
    loki_push_url        = "http://${aws_instance.telemetry[0].private_ip}:3100/loki/api/v1/push"
    prometheus_write_url = "http://${aws_instance.telemetry[0].private_ip}:9090/api/v1/write"
    otlp_http_endpoint   = "http://${aws_instance.telemetry[0].private_ip}:4318"
  } : null
}
