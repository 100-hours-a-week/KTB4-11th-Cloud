variable "dev_ai_telemetry_enabled" {
  description = "Include the existing development AI EC2 when development telemetry is enabled"
  type        = bool
  default     = true
}

variable "prod_ai_telemetry_enabled" {
  description = "Include the existing V1 AI EC2 in production telemetry without changing its applications"
  type        = bool
  default     = true
}

data "terraform_remote_state" "development_ai" {
  count   = var.plg_tempo_enabled && var.dev_telemetry_enabled && var.dev_ai_telemetry_enabled ? 1 : 0
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-ai-dev"
    key    = "ai-server/dev-infra/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "production_ai" {
  count   = var.plg_tempo_enabled && var.prod_ai_telemetry_enabled ? 1 : 0
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "ai-server/infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  ai_hosts = merge(
    var.plg_tempo_enabled && var.dev_telemetry_enabled && var.dev_ai_telemetry_enabled ? {
      dev = data.terraform_remote_state.development_ai[0].outputs
    } : {},
    var.plg_tempo_enabled && var.prod_ai_telemetry_enabled ? {
      prod = data.terraform_remote_state.production_ai[0].outputs
    } : {},
  )
  ai_ingestion = {
    for pair in setproduct(keys(local.ai_hosts), ["loki", "prometheus", "traces"]) : "${pair[0]}-${pair[1]}" => {
      environment = pair[0]
      port        = { loki = 3100, prometheus = 9090, traces = 4318 }[pair[1]]
    }
  }
}

data "aws_instance" "ai" {
  for_each    = local.ai_hosts
  instance_id = each.value.ai_instance_id
}

data "aws_subnet" "ai" {
  for_each = local.ai_hosts
  id       = data.aws_instance.ai[each.key].subnet_id
  lifecycle {
    postcondition {
      condition = each.key == "dev" ? (
        self.vpc_id == local.dev_host.vpc_id && self.id == local.dev_host.public_subnet_id
      ) : self.vpc_id == data.terraform_remote_state.shared.outputs.vpc_id
      error_message = "Development AI must share the configured development subnet route; production AI must stay in the production VPC."
    }
  }
}

resource "aws_route" "telemetry_to_development_ai" {
  count                     = contains(keys(local.ai_hosts), "dev") ? 1 : 0
  route_table_id            = data.aws_route_table.telemetry[0].id
  destination_cidr_block    = "${data.aws_instance.ai["dev"].private_ip}/32"
  vpc_peering_connection_id = local.dev_peering_id
}

resource "aws_vpc_security_group_ingress_rule" "ai_telemetry" {
  for_each                     = local.ai_ingestion
  security_group_id            = aws_security_group.telemetry[0].id
  referenced_security_group_id = local.ai_hosts[each.value.environment].ai_security_group_id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "${each.value.environment} AI EC2 to central ${each.value.port == 4318 ? "trace" : "log/metric"} ingestion"
  depends_on                   = [data.aws_subnet.ai, aws_vpc_peering_connection.development]
}

output "ai_telemetry" {
  description = "Existing AI EC2 agent targets; deployment is separate from Terraform apply"
  value = {
    for environment, host in local.ai_hosts : environment => {
      instance_id          = host.ai_instance_id
      private_ip           = data.aws_instance.ai[environment].private_ip
      environment          = environment
      cluster              = environment == "dev" ? "stockspoon-v2-dev" : "stockspoon-v1-ai"
      loki_push_url        = "http://${aws_instance.telemetry[0].private_ip}:3100/loki/api/v1/push"
      prometheus_write_url = "http://${aws_instance.telemetry[0].private_ip}:9090/api/v1/write"
      otlp_http_endpoint   = "http://${aws_instance.telemetry[0].private_ip}:4318"
    }
  }
}
