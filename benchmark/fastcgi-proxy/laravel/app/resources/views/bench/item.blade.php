<article id="p-{{ $item['id'] }}"><h2>{{ $item['title'] }}</h2><p>{{ number_format($item['price'], 2) }} EUR - {{ \Illuminate\Support\Carbon::parse($item['created'])->format('d.m.Y') }}</p>
<ul>@foreach ($item['tags'] as $tag)<li>{{ Str::upper($tag) }}</li>@endforeach</ul>
<form method="post" action="/cart/{{ $item['slug'] }}">@csrf<button>Add</button></form></article>
