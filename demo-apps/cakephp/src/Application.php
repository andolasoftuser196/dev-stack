<?php
declare(strict_types=1);

namespace App;

use Cake\Core\Configure;
use Cake\Http\BaseApplication;
use Cake\Http\MiddlewareQueue;
use Cake\Routing\Middleware\RoutingMiddleware;
use Cake\Routing\Router;
use Cake\Error\Middleware\ErrorHandlerMiddleware;

class Application extends BaseApplication
{
    public function bootstrap(): void
    {
        parent::bootstrap();
        Configure::write('debug', filter_var(ssmd_env('APP_DEBUG', 'true'), FILTER_VALIDATE_BOOL));

        // Initialise the route collection.
        //
        // Router::$_collection is a typed static with no default, and both the
        // routing middleware and the console reach for it. The application
        // skeleton does this; a hand-assembled project that does not gets
        // "Typed static property Cake\Routing\Router::$_collection must not be
        // accessed before initialization" from inside vendor/, on every request.
        Router::reload();
        $this->addPlugin('Migrations');

    }

    public function middleware(MiddlewareQueue $middlewareQueue): MiddlewareQueue
    {
        return $middlewareQueue
            ->add(new ErrorHandlerMiddleware(Configure::read('Error', [])))
            ->add(new RoutingMiddleware($this));
    }
}
