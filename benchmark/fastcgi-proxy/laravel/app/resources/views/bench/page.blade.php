@extends('bench.layout')
@section('content')
@foreach ($items as $item)
@include('bench.item', ['item' => $item])
@endforeach
@endsection
