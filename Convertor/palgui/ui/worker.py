"""worker.py - one palettize4 run at a time, off the GUI thread.

A QPROCESS AND NOT A QTHREAD, because the converter is a separate program, not
a function.  That is not a workaround: it is what makes the preview trustworthy
(it is the same process a shell would start, so it cannot behave differently
from the command line), and it is what makes Cancel real.  A thread running
numpy cannot be interrupted between rows; a process can simply be killed, and
an error-diffusion dither on a big source is exactly the case where you change
your mind ten seconds in.

SUPERSEDING IS THE NORMAL CASE, NOT AN ERROR.  Nudge the dither strength, press
Preview, nudge again: the second run kills the first.  A killed run must not
report failure - the user did not do anything wrong, and a red status bar for
having changed their mind would be noise.  Hence `superseded`, and hence the
generation counter: a process that dies after it has been replaced has its
output dropped on the floor rather than raced against the new one's.

THE STDOUT IS ACCUMULATED, NOT READ AT EXIT.  QProcess buffers are finite, and
--json prints a stats object that can run to several kilobytes with sixteen
palettes; draining on readyRead is the difference between that working and
deadlocking on a full pipe.
"""

from PySide6.QtCore import QObject, QProcess, QTimer, Signal

from .. import runner


class Worker(QObject):
    """Runs one Settings at a time and reports what came back."""

    #: (settings, out_dir, name) - a run actually started.
    started = Signal(object, str, str)
    #: (settings, out_dir, name, stats) - it worked.
    finished = Signal(object, str, str, object)
    #: (settings, RunError) - it did not.
    failed = Signal(object, object)
    #: Seconds since the current run started, once a second, for the status bar.
    tick = Signal(float)

    def __init__(self, parent=None):
        QObject.__init__(self, parent)
        self._proc = None
        self._gen = 0
        self._ctx = None            # (settings, out, name, generation)
        self._out = ''
        self._err = ''
        self._elapsed = 0.0
        self._timer = QTimer(self)
        self._timer.setInterval(1000)
        self._timer.timeout.connect(self._tick)

    # --- state ----------------------------------------------------------------
    def busy(self):
        return self._proc is not None

    def elapsed(self):
        return self._elapsed

    # --- running ---------------------------------------------------------------
    def start(self, settings, out, name=None):
        """Start a run, superseding any run already going."""
        self.cancel()
        self._gen += 1
        gen = self._gen
        try:
            cmd = runner.build_command(settings, out=out, name=name)
        except runner.RunError as exc:
            self.failed.emit(settings, exc)
            return

        self._ctx = (settings, out, name or settings.effective_name(), gen)
        self._out = ''
        self._err = ''
        self._elapsed = 0.0

        p = QProcess(self)
        p.setProgram(cmd[0])
        p.setArguments(cmd[1:])
        p.readyReadStandardOutput.connect(self._drain_out)
        p.readyReadStandardError.connect(self._drain_err)
        p.finished.connect(lambda code, status, g=gen: self._done(g, code))
        p.errorOccurred.connect(lambda err, g=gen: self._error(g, err))
        self._proc = p
        p.start()
        self._timer.start()
        self.started.emit(*self._ctx[:3])

    def cancel(self):
        """Kill the running process, if any.  Emits nothing - see the docstring."""
        self._timer.stop()
        p, self._proc = self._proc, None
        self._ctx = None
        if p is not None and p.state() != QProcess.NotRunning:
            p.kill()
            # Reap it so the OS handle goes away, but do not block the UI for
            # more than a moment if it is wedged.
            p.waitForFinished(1000)
        return p is not None

    # --- plumbing ----------------------------------------------------------------
    def _drain_out(self):
        if self._proc is not None:
            self._out += bytes(
                self._proc.readAllStandardOutput()).decode('utf-8', 'replace')

    def _drain_err(self):
        if self._proc is not None:
            self._err += bytes(
                self._proc.readAllStandardError()).decode('utf-8', 'replace')

    def _tick(self):
        self._elapsed += 1.0
        self.tick.emit(self._elapsed)

    def _stale(self, gen):
        """True if this callback belongs to a run that has been superseded."""
        return self._ctx is None or gen != self._ctx[3]

    def _error(self, gen, err):
        """QProcess could not even start it - a bad interpreter path, usually."""
        if self._stale(gen):
            return
        if err == QProcess.Crashed:
            # A kill lands here too, and a superseded run is already stale
            # above; anything reaching this point died on its own.
            return
        settings = self._ctx[0]
        self._timer.stop()
        self._proc = None
        self._ctx = None
        self.failed.emit(settings,
                         runner.RunError('could not start palettize4 (%s)'
                                         % err))

    def _done(self, gen, code):
        if self._stale(gen):
            return
        settings, out, name, _g = self._ctx
        self._drain_out()
        self._drain_err()
        self._timer.stop()
        self._proc = None
        self._ctx = None
        if code != 0:
            self.failed.emit(settings, runner.classify(code, self._err))
            return
        try:
            stats = runner.parse_stats(self._out, self._err)
        except runner.RunError as exc:
            self.failed.emit(settings, exc)
            return
        self.finished.emit(settings, out, name, stats)
