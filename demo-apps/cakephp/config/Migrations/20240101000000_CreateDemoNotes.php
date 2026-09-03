<?php
declare(strict_types=1);

use Migrations\AbstractMigration;

// One migration, so `dx db:migrate` has something to apply and each worktree
// instance builds a schema in its own database.
class CreateDemoNotes extends AbstractMigration
{
    public function change(): void
    {
        $this->table('demo_notes')
            ->addColumn('body', 'string', ['limit' => 255])
            ->addColumn('created', 'datetime', ['null' => true])
            ->create();
    }
}
