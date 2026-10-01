# Use direct metric tuples with the complete dimensions published by CWAgent.
# SEARCH expressions returned empty widgets even while these metrics had data.
resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "stockspoon-v1-app-use"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Stockspoon V1 · EC2 USE\n호스트 전체 지표입니다. CPU·메모리·디스크·네트워크 추세를 보고 병목 후보를 좁힙니다. FE/BE 컨테이너별 지표는 포함하지 않습니다."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "CPU active · all cores"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics = [[
            "CWAgent", "cpu_usage_active",
            "InstanceId", aws_instance.app.id,
            "InstanceType", var.ec2_instance_type,
            "cpu", "cpu-total",
            { stat = "Average", id = "cpuactive" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "Memory used"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics = [[
            "CWAgent", "mem_used_percent",
            "InstanceId", aws_instance.app.id,
            "InstanceType", var.ec2_instance_type,
            { stat = "Average", id = "memused" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "Root filesystem used"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics = [[
            "CWAgent", "disk_used_percent",
            "path", "/",
            "InstanceId", aws_instance.app.id,
            "InstanceType", var.ec2_instance_type,
            "fstype", "ext4",
            { stat = "Average", id = "diskused" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Runnable processes · proxy"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [[
            "CWAgent", "processes_running",
            "InstanceId", aws_instance.app.id,
            "InstanceType", var.ec2_instance_type,
            { stat = "Maximum", id = "processesrunning" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Disk I/O time · root device (nvme0n1)"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [[
            "CWAgent", "diskio_io_time",
            "InstanceId", aws_instance.app.id,
            "name", "nvme0n1",
            "InstanceType", var.ec2_instance_type,
            { stat = "Sum", id = "diskiotime" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Disk I/O requests · root device (nvme0n1)"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [[
            "CWAgent", "diskio_iops_in_progress",
            "InstanceId", aws_instance.app.id,
            "name", "nvme0n1",
            "InstanceType", var.ec2_instance_type,
            { stat = "Maximum", id = "diskiops" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "CPU I/O wait"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [[
            "CWAgent", "cpu_usage_iowait",
            "InstanceId", aws_instance.app.id,
            "InstanceType", var.ec2_instance_type,
            "cpu", "cpu-total",
            { stat = "Average", id = "cpuiowait" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Storage device errors · host logs"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [[
            "Stockspoon/USE", "StorageDeviceErrorCount",
            { stat = "Sum", id = "storageerrors" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Network bytes · primary interface (ens5)"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [
              "CWAgent", "net_bytes_sent",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "netbytessent" }
            ],
            [
              "CWAgent", "net_bytes_recv",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "netbytesrecv" }
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Network drops and errors · primary interface (ens5)"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [
              "CWAgent", "net_drop_in",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "netdropin" }
            ],
            [
              "CWAgent", "net_drop_out",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "netdropout" }
            ],
            [
              "CWAgent", "net_err_in",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "neterrin" }
            ],
            [
              "CWAgent", "net_err_out",
              "InstanceId", aws_instance.app.id,
              "InstanceType", var.ec2_instance_type,
              "interface", "ens5",
              { stat = "Sum", id = "neterrout" }
            ]
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 24
        width  = 24
        height = 4
        properties = {
          markdown = "## Reading the signals\n- CPU active: host compute use; sustained runnable-process growth alongside high CPU active is a CPU contention proxy, not an exact scheduler queue length.\n- CPU I/O wait rising with disk I/O time or in-progress requests suggests storage wait; confirm the signals together.\n- Memory used: sustained values near the alarm threshold warrant checking process memory and swap with Linux tools.\n- Disk I/O panels show the root device (nvme0n1); network panels show the EC2 primary interface (ens5).\n- Storage error count comes from system journal logs and common I/O error patterns; it appears only when matching log events are counted.\n- Network bytes show traffic; drops/errors should normally stay near zero."
        }
      },
    ]
  })
}
