# Terraform이 생성한 주요 인프라 식별자를 출력한다.
# apply 결과 확인 및 향후 다른 Terraform 구성이나 자동화에서 참조할 수 있다.

# StockSpoon V1에서 사용하는 VPC ID
output "vpc_id" {
  description = "ID of the StockSpoon V1 VPC"
  value       = aws_vpc.main.id
}

# 애플리케이션 EC2가 배치될 Public Subnet ID
output "public_subnet_id" {
  description = "ID of the public subnet for the application EC2"
  value       = aws_subnet.public.id
}

# 애플리케이션 EC2에 연결할 Security Group ID
output "app_security_group_id" {
  description = "ID of the security group for the application EC2"
  value       = aws_security_group.app.id
}
