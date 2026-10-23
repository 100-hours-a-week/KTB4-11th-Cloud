data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "ecs" {
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v2"
    key    = "ecs/terraform.tfstate"
    region = var.aws_region
  }
}

# Monitoring owns this connection. Read it without importing or changing it.
data "aws_vpc_peering_connection" "sse" {
  id = var.sse_vpc_peering_connection_id

  lifecycle {
    postcondition {
      condition = self.status == "active" && toset([self.vpc_id, self.peer_vpc_id]) == toset([
        data.terraform_remote_state.test_infra.outputs.vpc_id,
        data.terraform_remote_state.shared.outputs.vpc_id,
      ])
      error_message = "SSE access requires an active peering between the test and production VPCs."
    }
  }
}

data "aws_route_table" "load_generator" {
  subnet_id = data.terraform_remote_state.test_infra.outputs.public_subnet_id
}

data "aws_subnet" "sse" {
  for_each = toset(data.terraform_remote_state.shared.outputs.private_subnet_ids)
  id       = each.value
}

data "aws_route_tables" "sse" {
  vpc_id = data.terraform_remote_state.shared.outputs.vpc_id
  filter {
    name   = "association.subnet-id"
    values = data.terraform_remote_state.shared.outputs.private_subnet_ids
  }
}

# Route subnet CIDRs so replacement task ENIs remain reachable.
resource "aws_route" "load_generator_to_sse" {
  for_each                  = data.aws_subnet.sse
  route_table_id            = data.aws_route_table.load_generator.id
  destination_cidr_block    = each.value.cidr_block
  vpc_peering_connection_id = data.aws_vpc_peering_connection.sse.id
}

# Scope return routes to this load generator, preserving existing monitoring routes.
resource "aws_route" "sse_to_load_generator" {
  for_each                  = toset(data.aws_route_tables.sse.ids)
  route_table_id            = each.value
  destination_cidr_block    = "${aws_instance.sse_k6.private_ip}/32"
  vpc_peering_connection_id = data.aws_vpc_peering_connection.sse.id
}

resource "aws_vpc_security_group_ingress_rule" "sse_from_load_generator" {
  security_group_id            = data.terraform_remote_state.ecs.outputs.market_http_task_security_group_id
  referenced_security_group_id = aws_security_group.sse_k6.id
  from_port                    = var.sse_container_port
  to_port                      = var.sse_container_port
  ip_protocol                  = "tcp"
  description                  = "Dedicated SSE k6 over private VPC peering"
  depends_on                   = [data.aws_vpc_peering_connection.sse]
}
