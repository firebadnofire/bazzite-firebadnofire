#!/usr/bin/python3
"""Add honest, live bootc download activity to Anaconda's text UI."""

import argparse
import py_compile
import tempfile
from pathlib import Path


PROGRESS_MARKER = "__FBNF_BOOTC_DOWNLOAD__"
PATCH_MARKER = "bazzite-firebadnofire bootc download progress"


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one patch anchor, found {count}")
    return text.replace(old, new, 1)


def patch_payload(text):
    if PATCH_MARKER in text:
        return text

    text = replace_once(
        text,
        "import os\n",
        "import os\nimport queue\nimport threading\n",
        "Anaconda bootc payload imports",
    )
    class_start = text.find("class DeployBootcTask(Task):")
    if class_start < 0:
        raise RuntimeError("Anaconda bootc payload task was not found")
    try_anchor = '        try:\n            self.report_progress(_("Deploying image..."))\n'
    try_start = text.find(try_anchor, class_start)
    block_end = text.find("        except OSError as e:\n", try_start)
    if try_start < 0 or block_end < 0:
        raise RuntimeError("Anaconda bootc execution block did not match the expected contract")
    output_start = text.rfind("        bootc_output = []\n", class_start, try_start)
    if output_start >= 0 and not text[output_start + len("        bootc_output = []\n"):try_start].strip():
        block_start = output_start
    else:
        block_start = try_start

    replacement = f'''        # {PATCH_MARKER}. Anaconda's text UI otherwise appears frozen
        # while bootc pulls a large OCI image. Keep the subprocess reader in a
        # worker so this task can emit a truthful indeterminate heartbeat even
        # when bootc has not completed another output line yet.
        bootc_cmd = "bootc"
        bootc_output = []
        bootc_events = queue.Queue()
        bootc_error = None

        def read_bootc_output():
            try:
                for output_line in execReadlines(bootc_cmd, bootc_args):
                    bootc_events.put(("line", output_line))
            except Exception as error:  # Propagated unchanged on the task thread.
                bootc_events.put(("error", error))
            finally:
                bootc_events.put(("done", None))

        reader = threading.Thread(
            target=read_bootc_output,
            name="bootc-output-reader",
            daemon=True,
        )
        reader.start()
        heartbeat = 0
        try:
            self.report_progress(_("Deploying image..."))
            while True:
                try:
                    event, value = bootc_events.get(timeout=1.0)
                except queue.Empty:
                    heartbeat += 1
                    self.report_progress("{PROGRESS_MARKER}" + str(heartbeat))
                    continue

                if event == "line":
                    bootc_output.append(value)
                    self._parse_bootc_output(value)
                    heartbeat += 1
                    self.report_progress("{PROGRESS_MARKER}" + str(heartbeat))
                elif event == "error":
                    bootc_error = value
                elif event == "done":
                    break
                else:
                    raise RuntimeError("unexpected bootc progress event: " + event)

            reader.join()
            if bootc_error is not None:
                raise bootc_error
'''
    return text[:block_start] + replacement + text[block_end:]


def patch_tui(text):
    if PATCH_MARKER in text:
        return text

    class_start = text.find("class ProgressSpoke(")
    method_start = text.find("    def _on_progress_changed(self, step, message):\n", class_start)
    method_end = text.find("    def show_all(self):\n", method_start)
    if class_start < 0 or method_start < 0 or method_end < 0:
        raise RuntimeError("Anaconda text progress handler did not match the expected contract")

    replacement = f'''    def _on_progress_changed(self, step, message):
        """Handle a new progress report."""
        # {PATCH_MARKER}. This is deliberately indeterminate: bootc does not
        # expose a reliable total byte count through Anaconda's task API.
        if message.startswith("{PROGRESS_MARKER}"):
            tick = int(message[len("{PROGRESS_MARKER}"):])
            width = 28
            block_width = 7
            travel = width - block_width
            offset = tick % (travel * 2)
            if offset > travel:
                offset = travel * 2 - offset
            bar = " " * offset + "=" * block_width
            bar = bar.ljust(width)
            print(
                "\\r\\033[KDownloading operating system image [{{}}]".format(bar),
                flush=True,
                end="",
            )
            self._stepped = True
            return

        if message:
            if self._stepped:
                print('')
            print(message, flush=True)
            self._stepped = False
        else:
            print('.', flush=True, end='')
            self._stepped = True

'''
    return text[:method_start] + replacement + text[method_end:]


def patch_file(path, patcher):
    original = path.read_text(encoding="utf-8")
    updated = patcher(original)
    if updated != original:
        path.write_text(updated, encoding="utf-8")
    return updated


def find_anaconda_file(relative_path):
    matches = list(Path("/usr").glob(f"lib*/python*/site-packages/{relative_path}"))
    if len(matches) != 1:
        raise RuntimeError(
            f"expected one installed Anaconda file for {relative_path}, found {matches}"
        )
    return matches[0]


def self_test():
    payload_fixture = '''import os
class DeployBootcTask(Task):
    def run(self):
        bootc_args = []
        try:
            self.report_progress(_("Deploying image..."))
            for line in execReadlines("bootc", bootc_args):
                self._parse_bootc_output(line)
        except OSError as e:
            raise e
        log.info("Bootc deploy complete")
'''
    tui_fixture = '''class ProgressSpoke(Base):
    def _on_progress_changed(self, step, message):
        if message:
            if self._stepped:
                print('')
            print(message, flush=True)
            self._stepped = False
        else:
            print('.', flush=True, end='')
            self._stepped = True
    def show_all(self):
        pass
'''
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        payload = root / "payload.py"
        tui = root / "tui.py"
        payload.write_text(payload_fixture, encoding="utf-8")
        tui.write_text(tui_fixture, encoding="utf-8")
        first_payload = patch_file(payload, patch_payload)
        first_tui = patch_file(tui, patch_tui)
        if patch_file(payload, patch_payload) != first_payload:
            raise RuntimeError("payload patch is not idempotent")
        if patch_file(tui, patch_tui) != first_tui:
            raise RuntimeError("text UI patch is not idempotent")
        py_compile.compile(str(payload), doraise=True)
        py_compile.compile(str(tui), doraise=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--payload")
    parser.add_argument("--tui")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    payload = Path(args.payload) if args.payload else find_anaconda_file(
        "pyanaconda/modules/payloads/payload/rpm_ostree/installation.py"
    )
    tui = Path(args.tui) if args.tui else find_anaconda_file(
        "pyanaconda/ui/tui/spokes/installation_progress.py"
    )
    patch_file(payload, patch_payload)
    patch_file(tui, patch_tui)
    py_compile.compile(str(payload), doraise=True)
    py_compile.compile(str(tui), doraise=True)


if __name__ == "__main__":
    main()
