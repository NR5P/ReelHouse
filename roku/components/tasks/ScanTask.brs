' ScanTask - see ScanTask.xml.

sub init()
    m.top.functionName = "scan"
end sub

sub scan()
    device = CreateObject("roDeviceInfo")
    addresses = device.GetIPAddrs()
    candidates = []
    subnets = []
    seen = {}
    if rh_isAA(addresses) then
        for each iface in addresses
            ip = addresses[iface]
            if rh_isString(ip) then
                prefix = rh_subnetPrefix(ip)
                hosts = rh_subnetCandidates(ip, m.top.port)
                if prefix <> "" and hosts.Count() > 0 and not seen.DoesExist(prefix) then
                    seen[prefix] = true
                    subnets.Push(prefix + "0/24")
                    candidates.Append(hosts)
                end if
            end if
        end for
    end if
    m.top.subnets = subnets

    found = []
    total = candidates.Count()
    batchSize = m.top.batchSize
    if batchSize < 1 then batchSize = 32
    deadlineMs = m.top.deadlineMs
    port = CreateObject("roMessagePort")
    clock = CreateObject("roTimespan")
    i = 0
    while i < total
        ' Start a batch. A host that isn't there never answers at all (nothing to refuse the
        ' connection), so each batch gets a deadline and whatever hasn't answered by then is
        ' cancelled. A ReelHouse server on the LAN answers /api/health in a few milliseconds.
        batch = {}
        started = 0
        while started < batchSize and i < total
            base = candidates[i]
            xfer = CreateObject("roUrlTransfer")
            xfer.SetMessagePort(port)
            xfer.SetUrl(base + "/api/health")
            xfer.AddHeader("Accept", "application/json")
            if xfer.AsyncGetToString() then batch[Str(xfer.GetIdentity()).Trim()] = { xfer: xfer, base: base }
            i = i + 1
            started = started + 1
        end while

        clock.Mark()
        pending = batch.Count()
        while pending > 0
            remaining = deadlineMs - clock.TotalMilliseconds()
            if remaining <= 0 then exit while
            msg = wait(remaining, port)
            if msg = invalid then exit while
            if type(msg) = "roUrlEvent" then
                id = Str(msg.GetSourceIdentity()).Trim()
                entry = batch[id]
                if entry <> invalid then
                    batch.Delete(id)
                    pending = pending - 1
                    if msg.GetResponseCode() = 200 then
                        data = ParseJson(msg.GetString())
                        if rh_isReelHouseHealth(data) then
                            found.Push({ url: entry.base, address: rh_displayServer(entry.base), build: rh_buildLabel(data) })
                            m.top.found = found
                        end if
                    end if
                end if
            end if
        end while
        for each id in batch
            batch[id].xfer.AsyncCancel()
        end for
        m.top.progress = Int(i * 100 / total)
    end while

    m.top.found = found
    m.top.progress = 100
    m.top.done = true
end sub
