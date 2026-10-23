data "aws_ssm_parameter" "ubuntu_2604_ami" {
  name = "/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "sse_k6" {
  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.sse_k6_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.test_infra.outputs.public_subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.sse_k6.id]
  iam_instance_profile        = aws_iam_instance_profile.sse_k6.name

  user_data = join("\n", [
    file("${path.module}/k6_user_data.sh"),
    <<-SSE_BOOTSTRAP
      apt-get install -y golang-go
      install -d -m 0755 /opt/sse-k6 /usr/local/bin
      cd /opt/sse-k6
      GOTOOLCHAIN=auto GOMAXPROCS=2 go run go.k6.io/xk6/cmd/xk6@${var.sse_k6_xk6_version} build ${var.sse_k6_k6_version} \
        --with github.com/phymbert/xk6-sse@${var.sse_k6_extension_version} \
        --output /usr/local/bin/k6-sse
      chmod 0755 /usr/local/bin/k6-sse
      /usr/local/bin/k6-sse version
    SSE_BOOTSTRAP
  ])

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.sse_k6_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "${var.name_prefix}-sse-k6-root"
      Project     = "stockspoon"
      Environment = "loadtest"
      ManagedBy   = "Terraform"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name        = "${var.name_prefix}-sse-k6"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}
