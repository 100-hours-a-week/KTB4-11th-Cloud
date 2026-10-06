output "vpc_id" {
  description = "ID of the VPC shared by application workloads"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet shared by application workloads"
  value       = aws_subnet.public.id
}
