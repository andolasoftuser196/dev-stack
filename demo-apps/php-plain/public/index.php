<?php
declare(strict_types=1);

// No framework: the front controller is the whole application.
require dirname(__DIR__) . '/vendor/autoload.php';

header('Content-Type: text/plain; charset=utf-8');
echo Dx\Demo\Status::all('none');
