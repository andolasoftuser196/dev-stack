<?php
declare(strict_types=1);

// CakePHP serves from webroot/, not public/ - the single most common reason a
// CakePHP stack 404s on every route. runtime.docroot in the stack config must
// say webroot, and examples/runtimes/frankenphp-cakephp.stack.yml does.
use App\Application;
use Cake\Http\Server;

require dirname(__DIR__) . '/config/paths.php';
require dirname(__DIR__) . '/vendor/autoload.php';

$server = new Server(new Application(dirname(__DIR__) . '/config'));
$server->emit($server->run());
