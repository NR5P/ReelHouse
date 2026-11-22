using Xunit;

[assembly: AssemblyFixture(typeof(ReelHouse.Tests.TempDirectoryCleanup))]

namespace ReelHouse.Tests;

// Runs once, after the last test in this assembly. That timing is the whole point: see
// TempDirectories for why the SQLite pool must not be drained while tests are still running.
public sealed class TempDirectoryCleanup : IDisposable
{
    public void Dispose() => TempDirectories.DrainAndDelete();
}
