defmodule FLAME.Queue do
  defstruct tree: :gb_trees.empty(), keys: %{}, idx: 0, size: 0

  alias FLAME.Queue

  def new do
    %FLAME.Queue{}
  end

  def insert(%Queue{} = queue, value, key) do
    %Queue{tree: tree, keys: keys, idx: idx, size: size} = queue
    new_tree = :gb_trees.insert(idx, value, tree)
    new_keys = Map.put(keys, key, idx)
    %Queue{queue | tree: new_tree, keys: new_keys, idx: idx + 1, size: size + 1}
  end

  def pop(%Queue{tree: tree, idx: idx, size: size} = queue) do
    if size > 0 do
      {_key, value, new_tree} = :gb_trees.take_smallest(tree)
      new_idx = if :gb_trees.is_empty(new_tree), do: 0, else: idx
      {value, %Queue{queue | tree: new_tree, idx: new_idx, size: size - 1}}
    else
      {nil, queue}
    end
  end

  def pop_until(%Queue{} = queue, func) when is_function(func, 1) do
    case pop(queue) do
      {nil, %Queue{} = new_queue} ->
        {nil, new_queue}

      {value, %Queue{} = new_queue} ->
        if func.(value) do
          {value, new_queue}
        else
          pop_until(new_queue, func)
        end
    end
  end

  def get_by_key(%Queue{} = queue, key) do
    case queue.keys do
      %{^key => idx} ->
        {:value, value} = :gb_trees.lookup(idx, queue.tree)
        value

      %{} ->
        nil
    end
  end

  def delete_by_key(%Queue{tree: tree, keys: keys} = queue, key) do
    case keys do
      %{^key => index} ->
        new_tree = :gb_trees.delete_any(index, tree)
        new_keys = Map.delete(keys, key)
        new_idx = if :gb_trees.is_empty(new_tree), do: 0, else: queue.idx
        %Queue{queue | tree: new_tree, keys: new_keys, idx: new_idx, size: queue.size - 1}

      %{} ->
        queue
    end
  end
end
