defmodule Boombox.BrowserTest do
  use ExUnit.Case, async: false

  # Tests from this module are currently switched off on the CI because
  # they raise some errors there, that doesn't occur locally (probably
  # because of the problems with granting permissions for camera and
  # microphone access)

  require Logger

  @port 1235

  @moduletag :browser

  setup_all do
    browser_launch_opts = %{
      args: [
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream"
      ],
      headless: true
    }

    Application.put_env(:playwright, LaunchOptions, browser_launch_opts)
    {:ok, _apps} = Application.ensure_all_started(:playwright)

    :inets.stop()
    :ok = :inets.start()

    {:ok, _server} =
      :inets.start(:httpd,
        bind_address: ~c"localhost",
        port: @port,
        document_root: ~c"boombox_examples_data",
        server_name: ~c"assets_server",
        server_root: ~c"/tmp",
        erl_script_nocache: true
      )

    []
  end

  setup do
    {_pid, browser} = Playwright.BrowserType.launch(:chromium)

    on_exit(fn ->
      Playwright.Browser.close(browser)
    end)

    [browser: browser]
  end

  @tag :tmp_dir
  test "browser -> boombox -> mp4", %{browser: browser, tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "/webrtc_to_mp4.mp4")

    boombox_task =
      Task.async(fn ->
        Boombox.run(
          input: {:webrtc, "ws://localhost:8829"},
          output: output_path
        )
      end)

    ingress_page = start_page(browser, "webrtc_from_browser")

    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(ingress_page)
    assert_frames_encoded(ingress_page, seconds)

    close_page(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around ~850_000
    assert size > 400_000
  end

  @tag :tmp_dir
  test "browser -> (whip) boombox -> mp4", %{browser: browser, tmp_dir: tmp_dir} do
    output_path = Path.join(tmp_dir, "/webrtc_to_mp4.mp4")

    boombox_task =
      Task.async(fn ->
        Boombox.run(
          input: {:whip, "http://localhost:8829", token: "whip_it!"},
          output: output_path
        )
      end)

    ingress_page = start_page(browser, "whip")
    seconds = 10
    Process.sleep(seconds * 1000)

    assert_page_connected(ingress_page)
    assert_frames_encoded(ingress_page, seconds)

    close_page(ingress_page)

    Task.await(boombox_task)

    assert %{size: size} = File.stat!(output_path)
    # if things work fine, the size should be around ~850_000
    assert size > 400_000
  end

  for first <- [:ingress, :egress] do
    test "browser -> boombox -> browser, but #{first} browser page connects first", %{
      browser: browser
    } do
      boombox_task =
        Task.async(fn ->
          Boombox.run(
            input: {:webrtc, "ws://localhost:8829"},
            output: {:webrtc, "ws://localhost:8830"}
          )
        end)

      {ingress_page, egress_page} =
        case unquote(first) do
          :ingress ->
            ingress_page = start_page(browser, "webrtc_from_browser")
            Process.sleep(500)
            egress_page = start_page(browser, "webrtc_to_browser")
            {ingress_page, egress_page}

          :egress ->
            egress_page = start_page(browser, "webrtc_to_browser")
            Process.sleep(500)
            ingress_page = start_page(browser, "webrtc_from_browser")
            {ingress_page, egress_page}
        end

      seconds = 10
      Process.sleep(seconds * 1000)

      [ingress_page, egress_page]
      |> Enum.each(&assert_page_connected/1)

      assert_frames_encoded(ingress_page, seconds)
      assert_frames_decoded(egress_page, seconds)

      [ingress_page, egress_page]
      |> Enum.each(&close_page/1)

      Task.await(boombox_task)
    end
  end

  defp start_page(browser, page) do
    url = "http://localhost:#{@port}/#{page}.html"
    do_start_page(browser, url)
  end

  defp do_start_page(browser, url) do
    page = Playwright.Browser.new_page(browser)

    response = Playwright.Page.goto(page, url)
    assert response.status == 200

    Playwright.Page.click(page, "button[id=\"button\"]")

    page
  end

  defp close_page(page) do
    Playwright.Page.click(page, "button[id=\"button\"]")
    Playwright.Page.close(page)
  end

  defp assert_page_connected(page) do
    assert page
           |> Playwright.Page.text_content("[id=\"status\"]")
           |> String.contains?("Connected")
  end

  defp assert_frames_encoded(page, time_seconds) do
    fps_lowerbound = 12
    frames_encoded = get_webrtc_stats(page, type: "outbound-rtp", kind: "video").framesEncoded
    assert frames_encoded >= time_seconds * fps_lowerbound
  end

  defp assert_frames_decoded(page, time_seconds) do
    fps_lowerbound = 12
    frames_decoded = get_webrtc_stats(page, type: "inbound-rtp", kind: "video").framesDecoded
    assert frames_decoded >= time_seconds * fps_lowerbound
  end

  defp get_webrtc_stats(page, constraints) do
    js_fuj =
      "async () => {const stats = await window.pc.getStats(null); return Array.from(stats)}"

    Playwright.Page.evaluate(page, js_fuj)
    |> Enum.map(fn [_id, data] -> data end)
    |> Enum.find(fn stat -> Enum.all?(constraints, fn {k, v} -> stat[k] == v end) end)
  end
end
