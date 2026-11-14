import http.server
import pathlib
import shutil
import subprocess
import threading

requests = []
payload = bytes(range(256)) * 1024
resume_offset = 65536

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get("Range")))
        if self.path == "/missing":
            self.send_error(404)
            return
        start = 0
        if self.path == "/resume" and self.headers.get("Range"):
            start = int(self.headers["Range"].removeprefix("bytes=").split("-", 1)[0])
        self.send_response(206 if start else 200)
        if start:
            self.send_header("Content-Range", "bytes " + str(start) + "-" +
                             str(len(payload) - 1) + "/" + str(len(payload)))
        self.send_header("Content-Length", str(len(payload) - start))
        self.end_headers()
        self.wfile.write(payload[start:])

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever)
thread.start()
try:
    for backend in ("aria2c", "curl"):
        if shutil.which(backend) is None:
            print("SKIP: actual " + backend + " backend (not installed)", flush=True)
            continue
        config = pathlib.Path(backend + "-config")
        config.write_text(pathlib.Path("config").read_text() +
                          "\nPKGMK_DOWNLOAD_PROG=" + backend + "\n")
        for endpoint in ("fresh", "resume", "restart", "missing"):
            final = pathlib.Path(backend + "-" + endpoint)
            partial = pathlib.Path(endpoint + ".partial")
            with pathlib.Path("Pkgfile").open("a") as recipe:
                recipe.write("\nsource=(http://127.0.0.1:" + str(server.server_port) +
                             "/" + endpoint + ")\nrenames=(" + str(final) + ")\n")
            if endpoint != "fresh":
                partial.write_bytes(payload[:resume_offset])
            requests.clear()
            with open("out", "w") as out, open("err", "w") as err:
                result = subprocess.run(["/tmp/tools/pkgmk", "-cf", str(config), "-do"],
                                        stdout=out, stderr=err, timeout=30)
            if endpoint == "missing":
                assert result.returncode == 4, (backend, endpoint, result.returncode)
                assert not final.exists()
                assert not pathlib.Path(endpoint).exists()
            else:
                assert result.returncode == 0, (backend, endpoint, result.returncode)
                assert final.read_bytes() == payload, (backend, endpoint)
                assert not partial.exists(), (backend, endpoint)
            if endpoint == "resume":
                assert any(path == "/resume" and value and
                           value.startswith("bytes=" + str(resume_offset) + "-")
                           for path, value in requests), (backend, requests)
            if endpoint == "restart":
                assert any(path == "/restart" and value and
                           value.startswith("bytes=" + str(resume_offset) + "-")
                           for path, value in requests), (backend, requests)
                assert ("/restart", None) in requests, (backend, requests)
finally:
    server.shutdown()
    thread.join()
    server.server_close()
