<?php

namespace Tests\Feature;

use PHPUnit\Framework\TestCase;

final class StatusTest extends TestCase
{
    public function test_the_suite_runs_against_a_disposable_database(): void
    {
        $db = getenv('DB_DATABASE');
        if ($db === false || $db === '') {
            $this->markTestSkipped('no database configured');
        }
        // The same guard ssmd enforces, asserted from inside the project so it is
        // visible to anyone reading the app rather than only the toolkit.
        $this->assertMatchesRegularExpression('/(_test|_sandbox)$/', $db);
    }

    public function test_the_application_bootstraps(): void
    {
        $this->assertFileExists(dirname(__DIR__, 2) . '/bootstrap/app.php');
    }
}
