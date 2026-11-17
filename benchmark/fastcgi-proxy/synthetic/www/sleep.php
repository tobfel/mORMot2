<?php usleep(isset($_GET['ms']) ? (int)$_GET['ms'] * 1000 : 20000); echo "slept";
