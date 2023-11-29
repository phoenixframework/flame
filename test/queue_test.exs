defmodule FLAME.QueueTest do
  use ExUnit.Case

  alias FLAME.Queue

  describe "new/0" do
    test "creates a new Queue" do
      assert %Queue{} = Queue.new()
    end
  end

  describe "insert/3" do
    test "inserts a new item into the queue" do
      queue = Queue.insert(Queue.new(), "item1", :key1)
      assert queue.size == 1
      assert Queue.get_by_key(queue, :key1) == "item1"
    end
  end

  describe "pop/1" do
    test "pops the first item from the queue" do
      queue =
        Queue.new()
        |> Queue.insert("item1", :key1)
        |> Queue.insert("item2", :key2)

      {popped_item, %Queue{} = queue} = Queue.pop(queue)

      assert popped_item == "item1"
      assert queue.size == 1

      assert {"item2", %Queue{} = queue} = Queue.pop(queue)
      assert queue.size == 0
      assert queue.idx == 0
    end

    test "returns an error when the queue is empty" do
      assert {nil, %Queue{}} == Queue.pop(Queue.new())
    end
  end

  describe "pop_until/2" do
    test "pops until function returns true" do
      queue = Queue.new()
      assert Queue.pop_until(queue, fn _ -> true end) == {nil, queue}
      queue =
        Queue.new()
        |> Queue.insert(10, :key1)
        |> Queue.insert(11, :key2)
        |> Queue.insert(20, :key3)
        |> Queue.insert(30, :key4)

      assert {20, %Queue{} = queue} = Queue.pop_until(queue, fn i -> i >= 20 end)
      assert queue.size == 1
    end
  end

  describe "access" do
    test "retrieves an item by index" do
      queue =
        Queue.new()
        |> Queue.insert("item1", :key1)
        |> Queue.insert("item2", :key2)

      assert Queue.get_by_key(queue, :key1) == "item1"
      assert Queue.get_by_key(queue, :key2) == "item2"
    end

    test "returns nil for un unknown index or key" do
      queue = Queue.new()
      assert Queue.get_by_key(queue, :nope) == nil
    end
  end

  describe "delete_by_key/2" do
    test "deletes an item by its secondary key" do
      queue =
        Queue.new()
        |> Queue.insert("item1", :key1)
        |> Queue.insert("item2", :key2)

      queue = Queue.delete_by_key(queue, :key1)
      assert Queue.get_by_key(queue, :key1) == nil
      assert Queue.get_by_key(queue, :key2) == "item2"
      assert queue.size == 1
      assert queue.idx == 2
      queue = Queue.delete_by_key(queue, :key2)
      assert queue.size == 0
      assert queue.idx == 0

      queue = Queue.insert(queue, "item3", :key3)
      assert Queue.get_by_key(queue, :key3) == "item3"
      assert queue.size == 1
      assert queue.idx == 1
    end

    test "non-existent key" do
      queue = Queue.new()
      assert queue == Queue.delete_by_key(queue, :key1)
    end
  end
end
