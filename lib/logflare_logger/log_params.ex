defmodule LogflareLogger.LogParams do
  @moduledoc """
  Parses and encodes incoming Logger messages for further serialization.
  """
  alias LogflareLogger.{Stacktrace, Utils}
  @default_metadata_keys Utils.default_metadata_keys()

  @doc """
  Creates a LogParams struct when all fields have serializable values
  """
  def encode(timestamp, level, message, metadata) do
    new(timestamp, level, message, metadata)
    |> to_payload()
    |> jsonify()
    |> encode_metadata_charlists()
  end

  def new(timestamp, level, message, metadata) do
    log =
      %{
        timestamp: timestamp,
        level: level,
        message: message,
        metadata: metadata
      }
      |> encode_message()
      |> encode_timestamp()
      |> encode_metadata()

    {system_context, user_context} =
      log.metadata
      |> Map.split(@default_metadata_keys)

    log
    |> Map.drop([:metadata])
    |> Map.put(:context, %{
      system: system_context,
      user: user_context
    })
  end

  @doc """
  Encodes message, if is iodata converts to binary.
  """
  def encode_message(%{message: m} = log) do
    %{log | message: to_string(m)}
  end

  @doc """
  Converts erlang datetime tuple into ISO:Extended binary.
  """
  def encode_timestamp(%{timestamp: t} = log) when is_tuple(t) do
    timestamp =
      t
      |> Timex.to_naive_datetime()
      |> Timex.to_datetime(Timex.Timezone.local())
      |> Timex.format!("{ISO:Extended}")

    %{log | timestamp: timestamp}
  end

  def encode_metadata(%{metadata: meta} = log) do
    meta =
      meta
      |> encode_pid()
      |> encode_crash_reason()

    %{log | metadata: meta}
  end

  @doc """
  Converts pid to string
  """
  def encode_pid(%{pid: pid} = meta) when is_pid(pid) do
    pid =
      pid
      |> :erlang.pid_to_list()
      |> to_string()

    %{meta | pid: pid}
  end

  def encode_pid(meta), do: meta

  @doc """
  Adds formatted stacktrace to the metadata
  """
  def encode_crash_reason(%{crash_reason: cr} = meta) when not is_nil(cr) do
    {_err, stacktrace} = cr

    meta
    |> Map.drop([:crash_reason])
    |> Map.merge(%{stacktrace: Stacktrace.format(stacktrace)})
  end

  def encode_crash_reason(meta), do: meta

  @doc """
  jsonify deeply converts all keywords to maps and all atoms to strings
  for Logflare server to be able to safely convert binary to terms
  using :erlang.binary_to_term(binary, [:safe])
  """
  def jsonify(log) do
    Iteraptor.jsonify(log, values: true)
  end

  def to_payload(log) do
    metadata =
      %{}
      |> Map.merge(log.context[:user] || %{})
      |> Map.put(:context, log.context[:system] || %{})
      |> encode_metadata_charlists()

    log
    |> Map.put(:metadata, metadata)
    |> Map.drop([:context])
  end

  def encode_metadata_charlists(metadata) do
    for {k, v} <- metadata, into: Map.new() do
      v =
        cond do
          is_map(v) -> encode_metadata_charlists(v)
          is_list(v) and List.ascii_printable?(v) -> to_string(v)
          is_list(v) -> Enum.map(v, &encode_metadata_charlists/1)
          # TODO: iterate over tuples
          true -> v
        end

      {k, v}
    end
  def convert_tuples(data) when is_map(data) do
    data
    |> Enum.map(fn
      {k, v} when is_tuple(v) ->
        {k,
         v
         |> Tuple.to_list()
         |> convert_tuples()}

      {k, v} when is_map(v) when is_list(v) ->
        {k, convert_tuples(v)}

      {k, v} ->
        {k, v}
    end)
    |> Enum.into(Map.new())
  end

  def convert_tuples(data) when is_list(data) do
    data
    |> Enum.map(fn
      el when is_tuple(el) ->
        el
        |> Tuple.to_list()
        |> convert_tuples()

      el when is_map(el) when is_map(el) ->
        convert_tuples(el)

      el ->
        el
    end)
  end
end
