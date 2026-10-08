output "vpc_id" {
  description = "ID of the isolated load-test VPC"
  value       = aws_vpc.loadtest.id
}

output "public_subnet_id" {
  description = "ID of the public subnet that hosts both test EC2 instances"
  value       = aws_subnet.public.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets shared by development services"
  value       = [for key in sort(keys(aws_subnet.private)) : aws_subnet.private[key].id]
}

output "private_route_table_id" {
  description = "ID of the route table associated with the development private subnets"
  value       = aws_route_table.private.id
}

output "app_instance_id" {
  description = "ID of the load-test application EC2"
  value       = aws_instance.app.id
}

output "app_public_ip" {
  description = "Elastic IP of the load-test application EC2"
  value       = aws_eip.app.public_ip
}

output "app_private_ip" {
  description = "Private IP for k6 to target inside the VPC"
  value       = aws_instance.app.private_ip
}

output "app_public_url" {
  description = "HTTP URL for external access to the test application"
  value       = "http://${aws_eip.app.public_ip}"
}

output "k6_instance_id" {
  description = "ID of the k6 load generator EC2"
  value       = aws_instance.k6.id
}

output "k6_public_ip" {
  description = "Public IP of the k6 load generator EC2; it can change if the instance is replaced"
  value       = aws_instance.k6.public_ip
}

output "k6_private_ip" {
  description = "Private IP of the k6 load generator EC2"
  value       = aws_instance.k6.private_ip
}

output "k6_app_private_url" {
  description = "Private HTTP target URL for k6 scripts running in the VPC"
  value       = "http://${aws_instance.app.private_ip}"
}

output "app_ssh_user" {
  description = "Ubuntu SSH username"
  value       = "ubuntu"
}
