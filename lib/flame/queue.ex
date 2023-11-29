defmodule FLAME.Queue do
  @moduledoc false
  # Provides a FIFO queue with secondary key lookup/delete support.

  defstruct tree: :gb_trees.empty(), keys: %{}, idx: 0

  alias FLAME.Queue

  @doc """
  Builds a new queue.
  """
  def new, do: %FLAME.Queue{}

  @doc """
  Returns the size of the queue.
  """
  def size(%Queue{} = queue), do: :gb_trees.size(queue.tree)

  @doc """
  Inserts a new item into the queue with a secondary key.
  """
  def insert(%Queue{idx: idx} = queue, item, key) do
    new_tree = :gb_trees.insert(idx, {key, item}, queue.tree)
    new_keys = Map.put(queue.keys, key, idx)
    %Queue{queue | tree: new_tree, keys: new_keys, idx: idx + 1}
  end

  @doc """
  Pops an item from the queue returning the key/item pair.

  Returns `{nil, new_queue}` when the queue is empty.

  ## Examples

      iex> queue = Queue.insert(Queue.new(), "item1", :key1)
      iex> {{:key1, "item1"}, %Queue{} = new_queue} = Queue.pop(queue)
      iex> {nil, %Queue{} = new_queue} = Queue.pop(queue)
  """
  def pop(%Queue{tree: tree, keys: keys, idx: idx} = queue) do
    if size(queue) > 0 do
      {_smallest_idx, {key, val}, new_tree} = :gb_trees.take_smallest(tree)
      new_keys = Map.delete(keys, key)
      new_idx = if :gb_trees.is_empty(new_tree), do: 0, else: idx
      {{key, val}, %Queue{queue | tree: new_tree, keys: new_keys, idx: new_idx}}
    else
      {nil, queue}
    end
  end

  @doc """
  Pops items from the queue until the function returns true.

  Returns the first key/item pair for which the function returns true, and the new queue.
  """
  def pop_until(%Queue{} = queue, func) when is_function(func, 2) do
    case pop(queue) do
      {nil, %Queue{} = new_queue} ->
        {nil, new_queue}

      {{key, item}, %Queue{} = new_queue} ->
        if func.(key, item) do
          {{key, item}, new_queue}
        else
          pop_until(new_queue, func)
        end
    end
  end

  @doc """
  Looks up an item by key.

  Returns `nil` for unknown keys.

  ## Examples

      queue = Queue.insert(Queue.new(), "item1", :key1)
      "item1" = Queue.get_by_key(queue, :key1)
  """
  def get_by_key(%Queue{} = queue, key) do
    case queue.keys do
      %{^key => idx} ->
        {:value, {^key, item}} = :gb_trees.lookup(idx, queue.tree)
        item

      %{} ->
        nil
    end
  end

  @doc """
  Deletes an item by key.

  Unknown keys are ignored.

  ## Examples

      queue = Queue.insert(Queue.new(), "item1", :key1)
      new_queue = Queue.delete_by_key(queue, :key1)
  """
  def delete_by_key(%Queue{tree: tree, keys: keys} = queue, key) do
    case keys do
      %{^key => index} ->
        new_tree = :gb_trees.delete_any(index, tree)
        new_keys = Map.delete(keys, key)
        new_idx = if :gb_trees.is_empty(new_tree), do: 0, else: queue.idx
        %Queue{queue | tree: new_tree, keys: new_keys, idx: new_idx}

      %{} ->
        queue
    end
  end
end
