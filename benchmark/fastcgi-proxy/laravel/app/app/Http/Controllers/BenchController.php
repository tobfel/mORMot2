<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;
use Illuminate\View\View;

/** typical controller work without database: collections, helpers, Blade or JSON */
class BenchController extends Controller
{
    private function items(int $count): Collection
    {
        $base = Carbon::create(2026, 1, 1, 12);
        return collect(range(1, $count))->map(fn (int $i) => [
            'id' => $i,
            'title' => Str::title("product number $i of the catalog"),
            'slug' => Str::slug("Product Number $i"),
            'price' => round($i * 3.7, 2),
            'tags' => array_slice(['new', 'sale', 'eco', 'top', 'limited'], 0, $i % 5 + 1),
            'created' => $base->copy()->addDays($i)->toIso8601String(),
        ])->filter(fn (array $p) => $p['id'] % 7 !== 0)->sortByDesc('price')->values();
    }

    public function page(): View
    {
        return view('bench.page', ['items' => $this->items(50), 'title' => 'Catalog']);
    }

    public function json(): JsonResponse
    {
        $items = $this->items(100);
        return response()->json(['count' => $items->count(), 'items' => $items]);
    }
}
