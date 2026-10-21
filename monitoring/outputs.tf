output "plg_tempo" {
  description = "Independent V2 monitoring server (null while disabled)"
  value = var.plg_tempo_enabled ? {
    security_group_id    = aws_security_group.telemetry[0].id
    loki_push_url        = "http://${aws_instance.telemetry[0].private_ip}:3100/loki/api/v1/push"
    prometheus_write_url = "http://${aws_instance.telemetry[0].private_ip}:9090/api/v1/write"
    instance_id          = aws_instance.telemetry[0].id
    grafana_url          = local.grafana_public_enabled ? local.grafana_root_url : null
    private_ip           = aws_instance.telemetry[0].private_ip
    data_volume_id       = aws_ebs_volume.telemetry[0].id
    loki_bucket          = aws_s3_bucket.telemetry["loki"].id
    tempo_bucket         = aws_s3_bucket.telemetry["tempo"].id
    otlp_http_endpoint   = "http://${aws_instance.telemetry[0].private_ip}:4318"
    grafana_tunnel       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.telemetry[0].id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"13000\"]}'"
  } : null
  depends_on = [aws_volume_attachment.telemetry]
}
