using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace ScriptsPerso {
    public static class ProcessRunner {
        public static readonly ConcurrentQueue<string> Messages = new ConcurrentQueue<string>();
        // Zero preserves the launcher's existing, continuously drained output.
        public static int MaxQueuedMessages = 0;
        public static long DroppedMessages = 0;
        private static readonly ConcurrentDictionary<int, ProcessGroup> Groups = new ConcurrentDictionary<int, ProcessGroup>();
        private static readonly object ProcessStartLock = new object();

        private sealed class ProcessGroup : IDisposable {
            public readonly SafeFileHandle Job;
            public readonly EventWaitHandle StartGate;

            public ProcessGroup(SafeFileHandle job, EventWaitHandle startGate) {
                Job = job;
                StartGate = startGate;
            }

            public void Dispose() {
                StartGate.Dispose();
                Job.Dispose();
            }
        }

        private sealed class PrivateKeyMasker {
            private bool inside;
            public string Filter(string line) {
                bool begin = line.Contains("-----BEGIN ") && line.Contains("PRIVATE KEY-----");
                bool end = line.Contains("-----END ") && line.Contains("PRIVATE KEY-----");
                if (begin) { inside = !end; return "[CLE PRIVEE MASQUEE]"; }
                if (inside) { if (end) inside = false; return null; }
                return line;
            }
        }

        private static void QueueMessage(string message) {
            if (MaxQueuedMessages > 0 && message.Length > 8192)
                message = message.Substring(0, 8192) + " [ligne tronquee]";
            Messages.Enqueue(message);
            if (MaxQueuedMessages <= 0) return;
            string discarded;
            while (Messages.Count > MaxQueuedMessages && Messages.TryDequeue(out discarded))
                Interlocked.Increment(ref DroppedMessages);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits {
            public BasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref ExtendedLimits limits, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);

        public static string QuoteArgument(string value) {
            if (value == null) throw new ArgumentNullException("value");
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value) {
                if (character == '\\') {
                    slashes++;
                    continue;
                }
                result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
                result.Append(character);
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static bool StartWithUtf8Input(Process process) {
            var utf8 = new UTF8Encoding(false);
            var inputEncoding = typeof(ProcessStartInfo).GetProperty("StandardInputEncoding");
            if (inputEncoding != null) {
                inputEncoding.SetValue(process.StartInfo, utf8, null);
                return process.Start();
            }

            // Windows PowerShell 5.1 cible .NET Framework, qui ne propose pas
            // StandardInputEncoding. Process.Start capture alors l'encodage de
            // la console au moment où il construit le flux d'entrée redirigé.
            lock (ProcessStartLock) {
                var previous = Console.InputEncoding;
                try {
                    Console.InputEncoding = utf8;
                    return process.Start();
                }
                finally {
                    Console.InputEncoding = previous;
                }
            }
        }

        public static Process Launch(string executable, string arguments, string directory) {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                job.Dispose();
                throw new Win32Exception(error, "Impossible de creer le groupe de processus.");
            }
            var process = new Process();
            var gateName = @"Local\ScriptsPerso-" + Guid.NewGuid().ToString("N");
            var startGate = new EventWaitHandle(false, EventResetMode.ManualReset, gateName);
            bool started = false;
            bool registered = false;
            ProcessGroup group = null;
            try {
                var limits = new ExtendedLimits();
                // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE also cleans up descendants
                // if the launcher exits unexpectedly.
                limits.BasicLimitInformation.LimitFlags = 0x2000;
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Impossible de proteger le groupe de processus.");

                var psi = new ProcessStartInfo(executable, arguments);
                psi.WorkingDirectory = directory;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.RedirectStandardInput = true;
                psi.StandardOutputEncoding = new UTF8Encoding(false);
                psi.StandardErrorEncoding = new UTF8Encoding(false);
                psi.EnvironmentVariables["SCRIPTS_PERSO_START_GATE"] = gateName;
                process.StartInfo = psi;
                var outputMasker = new PrivateKeyMasker();
                var errorMasker = new PrivateKeyMasker();
                process.OutputDataReceived += (sender, eventArgs) => {
                    if (eventArgs.Data == null) return;
                    string line = MaxQueuedMessages > 0 ? outputMasker.Filter(eventArgs.Data) : eventArgs.Data;
                    if (line != null) QueueMessage("O" + line);
                };
                process.ErrorDataReceived += (sender, eventArgs) => {
                    if (eventArgs.Data == null) return;
                    string line = MaxQueuedMessages > 0 ? errorMasker.Filter(eventArgs.Data) : eventArgs.Data;
                    if (line != null) QueueMessage("E" + line);
                };
                StartWithUtf8Input(process);
                started = true;
                // La barriere nommee bloque l'outil jusqu'au rattachement au
                // Job Object, sans consommer son entree standard.
                if (!AssignProcessToJobObject(job, process.Handle))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Impossible d'isoler les sous-processus de l'outil.");
                group = new ProcessGroup(job, startGate);
                if (!Groups.TryAdd(process.Id, group))
                    throw new InvalidOperationException("Un groupe existe deja pour ce processus.");
                registered = true;
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                // Le runner peut maintenant ouvrir la barriere, même après ce
                // Set : le handle parent reste vivant jusqu'à Release().
                startGate.Set();
                return process;
            }
            catch {
                ProcessGroup removed;
                if (registered && Groups.TryRemove(process.Id, out removed)) {
                    TerminateJobObject(removed.Job, 1);
                    removed.Dispose();
                } else {
                    TerminateJobObject(job, 1);
                }
                if (started) {
                    try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { }
                }
                if (!registered) {
                    startGate.Dispose();
                    job.Dispose();
                }
                process.Dispose();
                throw;
            }
        }

        public static void Stop(Process process) {
            ProcessGroup group;
            if (!Groups.TryGetValue(process.Id, out group))
                throw new InvalidOperationException("Groupe de processus introuvable.");
            if (!TerminateJobObject(group.Job, 1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Impossible d'arreter le groupe de processus.");
        }

        public static void Release(Process process) {
            ProcessGroup group;
            if (Groups.TryRemove(process.Id, out group)) group.Dispose();
        }
    }
}
