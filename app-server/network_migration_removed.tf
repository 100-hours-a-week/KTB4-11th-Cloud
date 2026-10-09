# shared-infra state로 이전된 네트워크의 기존 관리 연결만 해제합니다.
# destroy = false이므로 실제 AWS 네트워크는 삭제하지 않습니다.
removed {
  from = aws_route_table_association.public

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route.internet

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route_table.public

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_internet_gateway.main

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_subnet.public

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_vpc.main

  lifecycle {
    destroy = false
  }
}
