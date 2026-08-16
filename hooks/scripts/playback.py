#!/usr/bin/env python3
"""Audio playback, by whichever route this machine can actually keep up with.

The obvious route — sounddevice straight out to the system audio server — is
broken under WSLg. Its PulseAudio RDP sink plays cleanly for about twenty
seconds after resuming from idle and then starves the audio callback for
hundreds of milliseconds at a time, degrading the longer it stays active and
surviving a stream close and reopen. Measured on 2026-08-16 with an identical
30s signal: through WSL audio, 30s of audio took 91.5s and stuttered; written
to a Windows path and played by Media.SoundPlayer, 32.6s and clean.

So there are two routes, and the machine picks. Nothing here knows about the
config file — the caller reads the setting and passes it in.

Import is stdlib-only: numpy and sounddevice are imported inside the methods
that need them, so selection and the WAV plumbing stay testable without the
Kokoro venv.
"""

import os
import shutil
import subprocess
import uuid
import wave

WINDOWS = 'windows'
SOUNDDEVICE = 'sounddevice'

# Where a WAV goes when the Windows temp directory cannot be located. Present
# on every Windows install and writable by a normal user.
FALLBACK_TEMP_WIN = r'C:\Windows\Temp'
FALLBACK_TEMP_WSL = '/mnt/c/Windows/Temp'


def select_backend(configured, proc_version, have_powershell):
    """Which route to use: WINDOWS or SOUNDDEVICE.

    Pure, so the decision can be tested without a kernel or an interop layer.
    An explicit setting always wins — detection can be wrong, and the config is
    the way out when it is. Anything unrecognised is treated as 'auto' rather
    than as a silent third behaviour.

    WSL with interop disabled is a real configuration, and choosing the Windows
    route there would leave the user mute. Silence is worse than the sputter
    this is here to fix, so a missing powershell falls back.
    """
    if configured == SOUNDDEVICE:
        return SOUNDDEVICE
    if configured == WINDOWS:
        return WINDOWS
    if 'microsoft' in (proc_version or '').lower() and have_powershell:
        return WINDOWS
    return SOUNDDEVICE


def build_player_command(win_path):
    """The Windows-side command that plays one WAV and exits when it drains.

    Its exit is what tells us playback finished, which is what the
    finished-speaking edge rests on — so this must block until the sound has
    actually played, not merely start it. Tests replace this wholesale.
    """
    return [
        'powershell.exe', '-NoProfile', '-Command',
        "(New-Object Media.SoundPlayer '%s').PlaySync()" % win_path,
    ]


def read_proc_version():
    try:
        with open('/proc/version', 'r') as f:
            return f.read()
    except OSError:
        return ''


def windows_temp_dirs():
    """(windows_path, wsl_path) for the Windows temp directory.

    Asked of Windows rather than assumed: the user's name is not a constant,
    and neither is the drive. Called once at startup, so the ~0.4s costs
    nothing per utterance.
    """
    try:
        out = subprocess.run(
            ['cmd.exe', '/c', 'echo %TEMP%'],
            capture_output=True, text=True, timeout=20,
        )
        win = out.stdout.strip().replace('\r', '')
        if win and '%TEMP%' not in win:
            conv = subprocess.run(
                ['wslpath', '-u', win],
                capture_output=True, text=True, timeout=20,
            )
            wsl = conv.stdout.strip()
            if wsl and os.path.isdir(wsl):
                return win, wsl
    except (OSError, subprocess.SubprocessError):
        pass
    return FALLBACK_TEMP_WIN, FALLBACK_TEMP_WSL


class WindowsPlayer:
    """Plays through Windows, bypassing the WSL audio stack entirely."""

    def __init__(self, temp_win, temp_wsl):
        self.temp_win = temp_win
        self.temp_wsl = temp_wsl
        # The WAV of the utterance in flight. Kept for cleanup and for anyone
        # trying to work out what was playing when something went wrong.
        self.last_path = None
        # Deliberately a plain attribute rather than a lock-guarded one: stop()
        # runs inside a signal handler, and a handler that blocks on a lock the
        # interrupted thread already holds is a deadlock.
        self._proc = None

    def play(self, audio, samplerate):
        import numpy as np
        pcm = (np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes()
        self.play_pcm(pcm, samplerate)

    def play_pcm(self, pcm, samplerate):
        """Write one utterance out and block until Windows has played it."""
        name = 'claude-voice-%s.wav' % uuid.uuid4().hex[:12]
        wsl_path = os.path.join(self.temp_wsl, name)
        win_path = self.temp_win.rstrip('\\') + '\\' + name
        self.last_path = wsl_path
        try:
            with wave.open(wsl_path, 'wb') as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(samplerate)
                w.writeframes(pcm)
            proc = subprocess.Popen(
                build_player_command(win_path), stdin=subprocess.DEVNULL)
            self._proc = proc
            proc.wait()
        finally:
            self._proc = None
            try:
                os.unlink(wsl_path)
            except OSError:
                pass

    def stop(self):
        """Cut playback short. A no-op when nothing is playing.

        Killing the WSL-side process terminates the Windows one — verified
        2026-08-16 by process count: 1 -> 2 while playing -> 1 after the kill,
        with nine seconds of audio left unplayed.
        """
        proc = self._proc
        if proc is None:
            return
        try:
            proc.kill()
        except OSError:
            pass


class SoundDevicePlayer:
    """The ordinary route: straight out through the system audio server."""

    def play(self, audio, samplerate):
        import sounddevice as sd
        sd.play(audio, samplerate=samplerate)
        sd.wait()

    def stop(self):
        import sounddevice as sd
        sd.stop()


def create_player(configured):
    """Build the player this machine should use. Returns (player, name)."""
    backend = select_backend(
        configured,
        read_proc_version(),
        shutil.which('powershell.exe') is not None,
    )
    if backend == WINDOWS:
        return WindowsPlayer(*windows_temp_dirs()), WINDOWS
    return SoundDevicePlayer(), SOUNDDEVICE
