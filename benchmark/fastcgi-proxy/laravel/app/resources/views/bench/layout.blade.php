<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="csrf-token" content="{{ csrf_token() }}"><title>{{ $title }}</title></head>
<body><header><h1>{{ $title }}</h1><nav><a href="{{ url('/') }}">Home</a></nav></header>
<main>@yield('content')</main><footer>&copy; {{ date('Y') }}</footer></body>
</html>
