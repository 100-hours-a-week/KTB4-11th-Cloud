output "vpc_id" {
  description = "ID of the VPC shared by application workloads"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet shared by application workloads"
  value       = aws_subnet.public.id
}

# 두 public subnet의 ID를 외부에서 참조할 수 있게 공개 (기존 public_subnet_id는 EC2가 참조하므로 유지)
output "public_subnet_ids" {
  description = "IDs of the shared public subnets across availability zones (2a, 2c)"
  value       = [aws_subnet.public.id, aws_subnet.public_c.id]
}
