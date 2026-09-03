#!/usr/bin/env php
<?php
declare(strict_types=1);

use App\Application;
use Cake\Console\CommandRunner;

require dirname(__DIR__) . '/config/paths.php';
require dirname(__DIR__) . '/vendor/autoload.php';

$runner = new CommandRunner(new Application(dirname(__DIR__) . '/config'), 'cake');
exit($runner->run($argv));
