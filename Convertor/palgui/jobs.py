"""jobs.py - the batch queue, as plain data.

A QUEUE IS HOW YOU COMPARE DITHERS ACROSS A SET, not just within one image.
`blue` beats `floyd` on a plasma and loses on a portrait, and the only way to
see that is to run the same options over several sources and read the resulting
colour counts next to each other.  Queueing the same image several times with
different dithers does the within-image comparison too, with every result kept
instead of overwritten.

A QUEUE RUNS TWO WAYS AND THE DIFFERENCE MATTERS.  Converting sends every job
to out/<name>/, so fifteen jobs on ONE image all write to one folder and each
destroys the last - which is exactly what you do NOT want when the fifteen are
variants you meant to compare.  Previewing sends them through a scratch
directory and keeps a numbered snapshot of each, so the same fifteen land side
by side in out/<name>/previews/ and palgui/review.py can walk them.  See
run_queue(preview=...) and Queue.collisions().

QT-FREE, like everything outside ui/.  A Queue can be built and run from a
script - see run_queue() - which is also how tests exercise it without a
display.  ui/joblist.py is a table over this, and owns none of it.
"""

import json
import os
import shutil
import tempfile

from . import runner, snapshot, summary
from .settings import Settings

#: A job that has never run.  The table shows this as an empty result column.
PENDING = 'pending'
RUNNING = 'running'
DONE = 'done'
FAILED = 'failed'


class Job(object):
    """One conversion: a Settings (which carries its own input and out) plus
    whatever came back the last time it ran."""

    def __init__(self, settings, label=''):
        self.settings = settings.clone()
        #: What the table calls it.  Defaults to the output base name, because
        #: that is what you will be looking for on disk afterwards.
        self.label = label or self.settings.effective_name() or '(unnamed)'
        self.state = PENDING
        self.stats = None
        self.error = ''
        #: (png, txt) when this job was PREVIEWED rather than converted.
        #: A preview's own output goes to a scratch directory that the next
        #: job overwrites and the app deletes on exit, so without this the
        #: row's picture would be whichever job happened to run last.
        self.snapshot = None

    # --- what the table shows -----------------------------------------------
    def source(self):
        return os.path.basename(self.settings.input) or '(no input)'

    def summary(self):
        """The result column: the numbers that let two rows be compared.

        PSNR IS HERE BECAUSE THE QUEUE IS WHERE COMPARING HAPPENS.  Queue one
        image at three colour biases and the column becomes the trade itself:
        the colour count climbs, the dB falls.  Reading that off a table beats
        opening three previews and holding them in your head.
        """
        if self.state == FAILED:
            return self.error
        if self.state == RUNNING:
            return 'running...'
        if self.state != DONE or not self.stats:
            return ''
        s = self.stats
        # A lossless run needs no accuracy number: the word already says the
        # output IS the ideal, and 'lossless, identical' is one word too many.
        if s.get('lossless'):
            return '%d colours, lossless' % s.get('output_colours', 0)
        psnr = summary.psnr_text(s)
        return ('%d colours, %.2f%% recoloured%s'
                % (s.get('output_colours', 0), s.get('recoloured_pct', 0.0),
                   ', %s' % psnr if psnr else ''))

    def note(self):
        """A warning that is not a failure, or ''.

        Right now that is only the inert-dither case, but it is the column that
        stops a queue of ten pixel-art images silently reporting ten successes
        for a dither that never ran.
        """
        if runner.dither_was_inert(self.settings, self.stats):
            return ('--dither %s had no effect: %d colours is inside the '
                    '%d budget, so no reduction ran'
                    % (self.settings.dither,
                       (self.stats or {}).get('master_colours', 0),
                       self.settings.colour_budget()))
        return ''

    def reset(self):
        self.state = PENDING
        self.stats = None
        self.error = ''
        self.snapshot = None

    def convert_target(self):
        """Where a CONVERSION of this job would write, as one string.

        The folder and the base name together, because that is the pair that
        collides: two jobs sharing both overwrite each other's eleven files.
        """
        return os.path.join(runner.job_dir(self.settings),
                            self.settings.effective_name())

    # --- serialisation --------------------------------------------------------
    def to_dict(self):
        # Results are not saved.  A queue file describes work to do; a stale
        # colour count from a source that has since been edited would be a lie
        # that looks exactly like a fact.
        return {'label': self.label, 'settings': self.settings.to_dict()}

    @classmethod
    def from_dict(cls, d):
        return cls(Settings.from_dict(d.get('settings', {})),
                   label=d.get('label', ''))


class Queue(object):
    """An ordered list of Jobs, savable as JSON."""

    def __init__(self, jobs=None):
        self.jobs = list(jobs or [])

    def __len__(self):
        return len(self.jobs)

    def __iter__(self):
        return iter(self.jobs)

    def __getitem__(self, i):
        return self.jobs[i]

    def add(self, settings, label=''):
        job = Job(settings, label=label)
        self.jobs.append(job)
        return job

    def remove(self, index):
        if 0 <= index < len(self.jobs):
            return self.jobs.pop(index)
        return None

    def move(self, index, delta):
        """Reorder.  Returns the new index, which the table re-selects."""
        j = index + delta
        if 0 <= index < len(self.jobs) and 0 <= j < len(self.jobs):
            self.jobs[index], self.jobs[j] = self.jobs[j], self.jobs[index]
            return j
        return index

    def retarget(self, path):
        """Point every job at a different image.  Returns how many moved.

        WHAT MAKES A SAVED QUEUE A SCRIPT.  Fifteen jobs is a worthwhile
        experiment to design once and a miserable one to retype, and the only
        thing separating "my dither comparison" from "my dither comparison OF
        THIS PICTURE" is fifteen copies of one path.

        --name IS CLEARED, NOT KEPT.  Fifteen jobs still called `plasma` after
        being pointed at eye.png would write eye.png's results into plasma's
        folder, all over each other - the precise collision this is meant to
        get you out of.  Blank lets palettize4 use the new stem.

        Results are dropped: they describe a different picture.
        """
        for job in self.jobs:
            job.settings.input = path
            job.settings.name = ''
            job.label = job.settings.effective_name() or job.label
            job.reset()
        return len(self.jobs)

    def collisions(self):
        """Jobs that a CONVERSION would have overwrite each other.

        -> [(target, [index, ...]), ...] for each target claimed more than
        once, in queue order.

        SAID BEFORE YOU PRESS RUN, not discovered afterwards.  Queueing one
        image several times with different dithers is the obvious way to set up
        a comparison, and converting it is the one thing that cannot produce
        one - every job writes the same eleven filenames.  Previewing has no
        collisions at all, because snapshots are numbered.
        """
        seen = {}
        for i, job in enumerate(self.jobs):
            seen.setdefault(job.convert_target(), []).append(i)
        return [(target, rows) for target, rows in seen.items()
                if len(rows) > 1]

    def clear(self):
        self.jobs = []

    def reset(self):
        for job in self.jobs:
            job.reset()

    def pending(self):
        return [j for j in self.jobs if j.state in (PENDING, FAILED)]

    def counts(self):
        """(done, failed, total) - the progress line."""
        done = sum(1 for j in self.jobs if j.state == DONE)
        failed = sum(1 for j in self.jobs if j.state == FAILED)
        return done, failed, len(self.jobs)

    # --- serialisation --------------------------------------------------------
    def save(self, path):
        with open(path, 'w') as f:
            json.dump({'jobs': [j.to_dict() for j in self.jobs]}, f, indent=2)
            f.write('\n')

    @classmethod
    def load(cls, path):
        with open(path) as f:
            d = json.load(f)
        return cls([Job.from_dict(x) for x in d.get('jobs', [])])


def run_queue(queue, on_progress=None, preview=False):
    """Run every job, in order, blocking.  Scripts and tests only.

    The GUI runs the same jobs through ui/worker.py so the window keeps
    painting; this exists so that the queue is not something you can ONLY use
    from a GUI, which for a batch feature would be a strange restriction.

    `preview=True` is the comparison mode: each job runs into one shared
    scratch directory and leaves a numbered snapshot under its own image's
    out/<name>/previews/, so a queue of fifteen variants ends as fifteen pairs
    to step through instead of one conversion written fifteen times.  The
    scratch directory is removed afterwards - the snapshots are the output.
    """
    scratch = tempfile.mkdtemp(prefix='palgui-queue-') if preview else None
    try:
        for i, job in enumerate(queue.jobs):
            job.state = RUNNING
            if on_progress:
                on_progress(i, job)
            try:
                if preview:
                    _preview_one(job, scratch)
                else:
                    # THE SAME DIRECTORY THE GUI USES.  This used to run into
                    # settings.out directly, so a scripted queue dropped every
                    # image's eleven files into one flat folder while the same
                    # queue through the window made one folder per image.  Two
                    # answers to "where did my output go" is one too many.
                    _convert_one(job)
                job.state = DONE
                job.error = ''
            except runner.RunError as exc:
                job.state = FAILED
                job.error = exc.message
            if on_progress:
                on_progress(i, job)
    finally:
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
    return queue.counts()


def _preview_one(job, scratch):
    """One job through the scratch directory, keeping only its snapshot.

    THE COMMAND LINE RECORDED IS THE CONVERT, not this run.  A recipe naming a
    temporary directory that no longer exists is not a recipe, and the summary
    is read weeks later - so the snapshot says --out out/<name>, which is what
    you would type to make this picture for real.  ui/main.py builds the same
    line for the same reason.
    """
    settings = job.settings
    job.stats = runner.run_blocking(settings, out=scratch,
                                    name=runner.PREVIEW_NAME)
    paths = runner.output_paths(job.stats, scratch)
    out_root = runner.resolve(settings.out)
    command = settings.command_line(script=os.path.basename(runner.SCRIPT),
                                    out=runner.job_dir(settings))
    _index, png, txt = snapshot.write_for_run(
        out_root, settings, job.stats, paths, command,
        summary.report_text(paths.get('report')))
    job.snapshot = (png, txt)


def _convert_one(job):
    """One job converted for real, plus its {name}_summary.txt record.

    The record is written HERE AND BY THE WINDOW through the same
    snapshot.write_conversion, so a scripted queue and a clicked Convert
    leave the same file.  A record that cannot be written does not fail the
    job - the eleven real files are already on disk.
    """
    settings = job.settings
    out = runner.resolve(runner.job_dir(settings))
    job.stats = runner.run_blocking(settings, out=out,
                                    name=settings.name or None)
    paths = runner.output_paths(job.stats, out)
    command = settings.command_line(script=os.path.basename(runner.SCRIPT),
                                    out=runner.job_dir(settings))
    try:
        snapshot.write_conversion(out, settings, job.stats, command,
                                  summary.report_text(paths.get('report')))
    except (OSError, KeyError, ValueError):     # noqa: BLE001 - see above
        pass
