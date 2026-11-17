<?php
$rows = [];
for ($i = 0; $i < 100; $i++)
  $rows[] = ['id' => $i, 'name' => "row $i", 'hash' => md5((string)$i), 'value' => $i * 1.5];
header('Content-Type: application/json');
echo json_encode(['count' => count($rows), 'rows' => $rows]);
