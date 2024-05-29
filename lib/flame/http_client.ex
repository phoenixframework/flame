defmodule FLAME.HttpClient do
  def post!(url, opts) do
    Keyword.validate!(opts, [:headers, :body, :connect_timeout, :content_type])

    headers =
      for {field, val} <- Keyword.fetch!(opts, :headers),
          do: {String.to_charlist(field), val}

    body = Keyword.fetch!(opts, :body)
    connect_timeout = Keyword.fetch!(opts, :connect_timeout)
    content_type = Keyword.fetch!(opts, :content_type)

    http_opts = [
      ssl:
        [
          verify: :verify_peer,
          depth: 2,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options(),
      connect_timeout: connect_timeout
    ]

    case :httpc.request(:post, {url, headers, ~c"#{content_type}", body}, http_opts, []) do
      {:ok, {{_, 201, _}, _, response_body}} ->
        Jason.decode!(response_body)

      {:ok, {{_, 200, _}, _, response_body}} ->
        Jason.decode!(response_body)

      {:ok, {{_, status, reason}, _, resp_body}} ->
        raise "failed POST #{url} with #{inspect(status)} (#{inspect(reason)}): #{inspect(resp_body)} #{inspect(headers)}"

      {:error, reason} ->
        raise "failed POST #{url} with #{inspect(reason)} #{inspect(headers)}"
    end
  end

  defp cacerts_options do
    cond do
      certs = otp_cacerts() ->
        [cacerts: certs]

      Application.spec(:castore, :vsn) ->
        [cacertfile: Application.app_dir(:castore, "priv/cacerts.pem")]

      true ->
        IO.warn("""
        No certificate trust store was found.

        A certificate trust store is required in
        order to download locales for your configuration.
        Since elixir_make could not detect a system
        installed certificate trust store one of the
        following actions may be taken:

        1. Use OTP 25+ on an OS that has built-in certificate
           trust store.

        2. Install the hex package `castore`. It will
           be automatically detected after recompilation.

        """)

        []
    end
  end

  if System.otp_release() >= "25" do
    defp otp_cacerts do
      :public_key.cacerts_get()
    rescue
      _ -> nil
    end
  else
    defp otp_cacerts, do: nil
  end
end
