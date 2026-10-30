output "vpc_id" {
  description = "ID of the isolated load-test VPC"
  value       = aws_vpc.loadtest.id
}

output "public_subnet_id" {
  description = "ID of the public subnet used by load-test and development EC2 instances"
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

output "dev_app_instance_id" {
  description = "ID of the single-host development Compose EC2"
  value       = aws_instance.dev_app.id
}

output "dev_app_public_ip" {
  description = "Elastic IP of the single-host development Compose EC2"
  value       = aws_eip.dev_app.public_ip
}

output "dev_app_public_url" {
  description = "HTTPS URL for the development application"
  value       = "https://${aws_eip.dev_app.public_ip}"
}

output "dev_app_private_ip" {
  description = "Private IP used by other services in the development VPC"
  value       = aws_instance.dev_app.private_ip
}

output "dev_app_private_url" {
  description = "Private HTTP URL for services inside the development VPC"
  value       = "http://${aws_instance.dev_app.private_ip}"
}

output "dev_app_security_group_id" {
  description = "Dedicated Security Group attached to the development Compose EC2"
  value       = aws_security_group.dev_app.id
}

output "dev_app_iam_role_name" {
  description = "Dedicated IAM Role attached to the development Compose EC2"
  value       = aws_iam_role.dev_app.name
}
