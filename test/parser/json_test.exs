defmodule FLAME.Parser.JSONTest do
  use ExUnit.Case, async: false

  alias FLAME.Parser.JSON

  describe "encode!/1" do
    test "should encode string" do
      assert JSON.encode!("foo") == "\"foo\""
    end

    test "should encode atom" do
      assert JSON.encode!(:FLAME) == "\"FLAME\""
    end

    test "should encode string maps" do
      assert JSON.encode!(%{"foo" => "bar"}) == "{\"foo\":\"bar\"}"
    end

    test "should encode atom maps" do
      assert JSON.encode!(%{foo: "bar"}) == "{\"foo\":\"bar\"}"
    end

    test "should encode list" do
      assert JSON.encode!([%{foo: "bar"}]) == "[{\"foo\":\"bar\"}]"
    end
  end

  describe "decode!/1" do
    test "should decode string" do
      assert JSON.decode!("\"foo\"") == "foo"
    end

    test "should decode maps" do
      assert JSON.decode!("{\"foo\":\"bar\"}") == %{"foo" => "bar"}
    end

    test "should decode list" do
      assert JSON.decode!("[{\"foo\":\"bar\"}]") == [%{"foo" => "bar"}]
    end
  end

  describe "json parser" do
    test "correct json parser based on erlang json availability" do
      if Code.ensure_loaded?(:json) do
        assert JSON.json_parser() == :json
      else
        assert JSON.json_parser() == Jason
      end
    end
  end
end