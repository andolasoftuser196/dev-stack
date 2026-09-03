<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

// One migration, so `dx db:migrate` has something to do and `dx wt add` has a
// schema to build in each instance's own database.
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('demo_notes', function (Blueprint $table) {
            $table->id();
            $table->string('body');
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('demo_notes');
    }
};
