using System.Security.Cryptography;
using Makaretu.Dns;

namespace ReelHouse;

// Advertises this server as "_reelhouse._tcp" over mDNS/DNS-SD (RFC 6762/6763), so the iOS
// and Android setup screens can list it instead of the user typing an IP address. A dedicated
// service type - not "_http._tcp" - so a client's browse results only ever contain ReelHouse
// servers, with no further filtering needed on the client side.
//
// Deliberately carries no secrets in the TXT records (no API key, no certificate fingerprint):
// this is unrelated, unauthenticated multicast traffic on the LAN, so it should reveal nothing
// more than a port scan already would. The client still goes through /api/health and the normal
// login flow after resolving an address from here.
public sealed class MdnsAdvertiserService(
    DiscoverySettings settings,
    DiscoveryEndpoint endpoint,
    ILogger<MdnsAdvertiserService> logger) : BackgroundService
{
    private const string ServiceType = "_reelhouse._tcp";

    // Bumped only if the discovery TXT schema itself changes shape - not tied to the app or API
    // version - so an older client can tell a differently-shaped payload apart from a missing one.
    private const string DiscoveryProtocolVersion = "1";

    private ServiceDiscovery? _serviceDiscovery;

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!settings.Enabled)
        {
            logger.LogInformation("Local-network discovery is disabled (Discovery:Enabled is false).");
            return Task.CompletedTask;
        }

        try
        {
            var instanceName = string.IsNullOrWhiteSpace(settings.InstanceName)
                ? Environment.MachineName
                : settings.InstanceName;
            var scheme = endpoint.UseHttps ? "https" : "http";

            // Not persisted anywhere - it only needs to stay stable for as long as this process
            // runs, to tell two same-hostname boxes on one LAN apart in a client's picker list.
            var instanceId = string.IsNullOrWhiteSpace(settings.InstanceId)
                ? RandomNumberGenerator.GetHexString(8, lowercase: true)
                : settings.InstanceId;

            var profile = new ServiceProfile(instanceName, ServiceType, (ushort)endpoint.Port);
            profile.AddProperty("scheme", scheme);
            profile.AddProperty("protoVersion", DiscoveryProtocolVersion);
            profile.AddProperty("instanceId", instanceId);
            // The server's own LAN addresses, so an app can connect straight away instead of
            // resolving the service's host name first - that resolve step is what hung on Apple
            // TV. Virtual adapters (the download VPN's veth, Docker...) are left out.
            var addresses = LocalNetworkInterfaces.GetCandidateInterfaces()
                .Where(i => !i.LooksVirtual).Select(i => i.Address).Distinct().ToList();
            if (addresses.Count > 0)
            {
                profile.AddProperty("addrs", string.Join(",", addresses));
                profile.AddProperty("port", endpoint.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }

            // Owns its own MulticastService (default constructor) and auto-starts - no separate
            // Start() call needed, and disposing it in StopAsync below is enough cleanup.
            _serviceDiscovery = new ServiceDiscovery();
            _serviceDiscovery.Advertise(profile);

            logger.LogInformation(
                "Advertising ReelHouse on the local network as {InstanceName} ({Scheme} port {Port}).",
                instanceName, scheme, endpoint.Port);
        }
        catch (Exception ex)
        {
            // A host with no active NIC, or a container/namespace that can't join multicast,
            // must degrade to "no local-network discovery" rather than take the whole dashboard
            // down over what is only ever a convenience feature - manual IP entry still works.
            logger.LogWarning(ex, "Could not start local-network discovery (mDNS). Manual server address entry is unaffected.");
        }

        return Task.CompletedTask;
    }

    public override Task StopAsync(CancellationToken cancellationToken)
    {
        try
        {
            _serviceDiscovery?.Dispose();
        }
        catch (Exception ex)
        {
            // Makaretu.Dns's MulticastClient.Dispose intermittently throws "Collection was
            // modified" when a receive loop races its own teardown. Nothing to clean up beyond
            // what its Dispose already attempted, and an exception here would otherwise abort
            // host shutdown - seen as spurious failures in whichever test happened to be
            // disposing its WebApplicationFactory at the time.
            logger.LogDebug(ex, "Ignoring mDNS teardown failure during shutdown.");
        }
        return base.StopAsync(cancellationToken);
    }
}
