using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace ReelHouse;

// One IPv4 address this machine has on a network adapter, and whether that adapter looks like a
// virtual one (a VPN, a container bridge) rather than the home network.
public sealed record ScanInterface(string Name, string Description, string Address, int PrefixLength, bool LooksVirtual);

public static class LocalNetworkInterfaces
{
    private static readonly string[] VirtualAdapterHints =
    [
        "virtual", "vmware", "virtualbox", "vbox", "hyper-v", "vethernet", "docker", "veth", "br-",
        "tailscale", "zerotier", "wireguard", "wg", "tun", "tap", "utun", "bridge", "vpn", "loopback"
    ];

    public static bool IsLikelyVirtualAdapter(string name, string description) =>
        VirtualAdapterHints.Any(hint =>
            name.Contains(hint, StringComparison.OrdinalIgnoreCase) ||
            description.Contains(hint, StringComparison.OrdinalIgnoreCase));

    public static IReadOnlyList<ScanInterface> GetCandidateInterfaces()
    {
        var results = new List<ScanInterface>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp)
                continue;

            var looksVirtual = IsLikelyVirtualAdapter(nic.Name, nic.Description);

            foreach (var address in nic.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                results.Add(new ScanInterface(nic.Name, nic.Description, address.Address.ToString(), address.PrefixLength, looksVirtual));
            }
        }
        return results;
    }
}
