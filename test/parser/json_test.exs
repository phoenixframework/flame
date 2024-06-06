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
end
