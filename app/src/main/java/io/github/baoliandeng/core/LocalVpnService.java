package io.github.baoliandeng.core;

import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.SharedPreferences.Editor;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import go.client.Client;
import io.github.baoliandeng.R;
import io.github.baoliandeng.core.ProxyConfig.IPAddress;
import io.github.baoliandeng.dns.DnsPacket;
import io.github.baoliandeng.tcpip.CommonMethods;
import io.github.baoliandeng.tcpip.IPHeader;
import io.github.baoliandeng.tcpip.TCPHeader;
import io.github.baoliandeng.tcpip.UDPHeader;
import io.github.baoliandeng.ui.MainActivity;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;


public class LocalVpnService extends VpnService implements Runnable {

    public static LocalVpnService Instance;
    public static boolean IsRunning = false;

    private final String device = android.os.Build.DEVICE;
    private final String model = android.os.Build.MODEL;
    private final String version = "" + android.os.Build.VERSION.SDK_INT + " ("  + android.os.Build.VERSION.RELEASE + ")";

    private static int ID;
    private static int LOCAL_IP;
    private static ConcurrentHashMap<onStatusChangedListener, Object> m_OnStatusChangedListeners = new ConcurrentHashMap<onStatusChangedListener, Object>();

    private Thread m_VPNThread;
    private ParcelFileDescriptor m_VPNInterface;
    private TcpProxyServer m_TcpProxyServer;
    private DnsProxy m_DnsProxy;
    private FileOutputStream m_VPNOutputStream;

    private byte[] m_Packet;
    private IPHeader m_IPHeader;
    private TCPHeader m_TCPHeader;
    private UDPHeader m_UDPHeader;
    private ByteBuffer m_DNSBuffer;
    private Handler m_Handler;
    private long m_SentBytes;
    private long m_ReceivedBytes;

    public LocalVpnService() {
        ID++;
        m_Handler = new Handler();
        m_Packet = new byte[20000];
        m_IPHeader = new IPHeader(m_Packet, 0);
        m_TCPHeader = new TCPHeader(m_Packet, 20);
        m_UDPHeader = new UDPHeader(m_Packet, 20);
        m_DNSBuffer = ((ByteBuffer) ByteBuffer.wrap(m_Packet).position(28)).slice();
        Instance = this;

        Log.d("BaoLianDeng", "New VPNService" + ID);
    }

    public static void addOnStatusChangedListener(onStatusChangedListener listener) {
        if (!m_OnStatusChangedListeners.containsKey(listener)) {
            m_OnStatusChangedListeners.put(listener, 1);
        }
    }

    public static void removeOnStatusChangedListener(onStatusChangedListener listener) {
        if (m_OnStatusChangedListeners.containsKey(listener)) {
            m_OnStatusChangedListeners.remove(listener);
        }
    }

    @Override
    public void onCreate() {
        Log.d("BaoLianDeng", "VPNService created" + ID);
        // Start a new session by creating a new thread.
        m_VPNThread = new Thread(this, "VPNServiceThread");
        m_VPNThread.start();

        writeLog("This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.");
        writeLog("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.");

        writeLog("This program includes two other open source programs:");
        writeLog("SmartProxy Copyright (C) 2014 hedaode. GPLv3");
        writeLog("Lantern Copyright 2010 Brave New Software Project, Inc. Apache 2.0");

        super.onCreate();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        IsRunning = true;
        return super.onStartCommand(intent, flags, startId);
    }

    private void onStatusChanged(final String status, final boolean isRunning) {
        m_Handler.post(new Runnable() {
            @Override
            public void run() {
                for (Map.Entry<onStatusChangedListener, Object> entry : m_OnStatusChangedListeners.entrySet()) {
                    entry.getKey().onStatusChanged(status, isRunning);
                }
            }
        });
    }

    public void writeLog(final String format, Object... args) {
        final String logString = String.format(format, args);
        m_Handler.post(new Runnable() {
            @Override
            public void run() {
                for (Map.Entry<onStatusChangedListener, Object> entry : m_OnStatusChangedListeners.entrySet()) {
                    entry.getKey().onLogReceived(logString);
                }
            }
        });
    }

    public void sendUDPPacket(IPHeader ipHeader, UDPHeader udpHeader) {
        try {
            CommonMethods.ComputeUDPChecksum(ipHeader, udpHeader);
            this.m_VPNOutputStream.write(ipHeader.m_Data, ipHeader.m_Offset, ipHeader.getTotalLength());
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    String getAppInstallID() {
        SharedPreferences preferences = getSharedPreferences("BaoLianDeng", MODE_PRIVATE);
        String appInstallID = preferences.getString("AppInstallID", null);
        if (appInstallID == null || appInstallID.isEmpty()) {
            appInstallID = UUID.randomUUID().toString();
            Editor editor = preferences.edit();
            editor.putString("AppInstallID", appInstallID);
            editor.commit();
        }
        return appInstallID;
    }

    String getVersionName() {
        try {
            PackageManager packageManager = getPackageManager();
            PackageInfo packInfo = packageManager.getPackageInfo(getPackageName(), 0);
            String version = packInfo.versionName;
            return version;
        } catch (Exception e) {
            return "0.0";
        }
    }

    @Override
    public synchronized void run() {
        try {
            Log.d("BaoLianDeng", "VPNService work thread is running... " + ID);

            ProxyConfig.AppInstallID = getAppInstallID();
            ProxyConfig.AppVersion = getVersionName();
            writeLog("Android version: %s", Build.VERSION.RELEASE);
            writeLog("App version: %s", ProxyConfig.AppVersion);

            ChinaIpMaskManager.loadFromFile(getResources().openRawResource(R.raw.ipmask));

            waitUntilPreapred();

            m_TcpProxyServer = new TcpProxyServer(0);
            m_TcpProxyServer.start();
            writeLog("LocalTcpServer started.");

            m_DnsProxy = new DnsProxy();
            m_DnsProxy.start();
            writeLog("LocalDnsProxy started.");

            Client.Provider.Stub stub = new Client.Provider.Stub() {
                public boolean Verbose() {
                    return ProxyConfig.IS_DEBUG;
                }
                public String Model() {
                    return model;
                }
                public String Device() {
                    return device;
                }
                public String Version() {
                    return version;
                }
                public String AppName() {
                    return "Lantern";
                }
                public String SettingsDir() {
                    File f = getFilesDir();
                    if (f != null) return f.getPath();
                    return "/data/data/io.github.baoliandeng";
                }
                public void Protect(long fd) {
                    protect((int) fd);
                }
            };

            Client.Configure(stub);
            Client.Start(stub);

            Thread.sleep(1000*2);

            while (true) {
                if (IsRunning) {
                    runVPN();
                } else {
                    Thread.sleep(100);
                }
            }
        } catch (InterruptedException e) {
            Log.e("BaoLianDeng", "Exception", e);
        } catch (Exception e) {
            e.printStackTrace();
            writeLog("Fatal error: %s", e.toString());
        } finally {
            writeLog("BaoLianDeng terminated.");
            dispose();
        }
    }

    private void runVPN() throws Exception {
        this.m_VPNInterface = establishVPN();
        this.m_VPNOutputStream = new FileOutputStream(m_VPNInterface.getFileDescriptor());
        FileInputStream in = new FileInputStream(m_VPNInterface.getFileDescriptor());
        int size = 0;
        while (size != -1 && IsRunning) {
            while ((size = in.read(m_Packet)) > 0 && IsRunning) {
                if (m_DnsProxy.Stopped || m_TcpProxyServer.Stopped) {
                    in.close();
                    throw new Exception("LocalServer stopped.");
                }
                onIPPacketReceived(m_IPHeader, size);
            }
            Thread.sleep(100);
        }
        in.close();
        disconnectVPN();
    }

    void onIPPacketReceived(IPHeader ipHeader, int size) throws IOException {
        switch (ipHeader.getProtocol()) {
            case IPHeader.TCP:
                TCPHeader tcpHeader = m_TCPHeader;
                tcpHeader.m_Offset = ipHeader.getHeaderLength();
                if (ipHeader.getSourceIP() == LOCAL_IP) {
                    if (tcpHeader.getSourcePort() == m_TcpProxyServer.Port) {
                        NatSession session = NatSessionManager.getSession(tcpHeader.getDestinationPort());
                        if (session != null) {
                            ipHeader.setSourceIP(ipHeader.getDestinationIP());
                            tcpHeader.setSourcePort(session.RemotePort);
                            ipHeader.setDestinationIP(LOCAL_IP);

                            CommonMethods.ComputeTCPChecksum(ipHeader, tcpHeader);
                            m_VPNOutputStream.write(ipHeader.m_Data, ipHeader.m_Offset, size);
                            m_ReceivedBytes += size;
                        } else {
                            if (ProxyConfig.IS_DEBUG)
                                Log.d("BaoLianDeng", "NoSession: " +
                                        ipHeader.toString() + " " +
                                        tcpHeader.toString());
                        }
                    } else {
                        int portKey = tcpHeader.getSourcePort();
                        NatSession session = NatSessionManager.getSession(portKey);
                        if (session == null || session.RemoteIP != ipHeader.getDestinationIP() || session.RemotePort != tcpHeader.getDestinationPort()) {
                            session = NatSessionManager.createSession(portKey, ipHeader.getDestinationIP(), tcpHeader.getDestinationPort());
                        }

                        session.LastNanoTime = System.nanoTime();
                        session.PacketSent++;

                        int tcpDataSize = ipHeader.getDataLength() - tcpHeader.getHeaderLength();
                        if (session.PacketSent == 2 && tcpDataSize == 0) {
                            return;
                        }

                        if (session.BytesSent == 0 && tcpDataSize > 10) {
                            int dataOffset = tcpHeader.m_Offset + tcpHeader.getHeaderLength();
                            String host = HttpHostHeaderParser.parseHost(tcpHeader.m_Data, dataOffset, tcpDataSize);
                            if (host != null) {
                                session.RemoteHost = host;
                            }
                        }

                        ipHeader.setSourceIP(ipHeader.getDestinationIP());
                        ipHeader.setDestinationIP(LOCAL_IP);
                        tcpHeader.setDestinationPort(m_TcpProxyServer.Port);

                        CommonMethods.ComputeTCPChecksum(ipHeader, tcpHeader);
                        m_VPNOutputStream.write(ipHeader.m_Data, ipHeader.m_Offset, size);
                        session.BytesSent += tcpDataSize;
                        m_SentBytes += size;
                    }
                }
                break;
            case IPHeader.UDP:
                UDPHeader udpHeader = m_UDPHeader;
                udpHeader.m_Offset = ipHeader.getHeaderLength();
                if (ipHeader.getSourceIP() == LOCAL_IP && udpHeader.getDestinationPort() == 53) {
                    m_DNSBuffer.clear();
                    m_DNSBuffer.limit(ipHeader.getDataLength() - 8);
                    DnsPacket dnsPacket = DnsPacket.FromBytes(m_DNSBuffer);
                    if (dnsPacket != null && dnsPacket.Header.QuestionCount > 0) {
                        m_DnsProxy.onDnsRequestReceived(ipHeader, udpHeader, dnsPacket);
                    }
                }
                break;
        }
    }

    private void waitUntilPreapred() {
        while (prepare(this) != null) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                // Ignore
            }
        }
    }

    private ParcelFileDescriptor establishVPN() throws Exception {
        Builder builder = new Builder();
        builder.setMtu(ProxyConfig.Instance.getMTU());

        IPAddress ipAddress = ProxyConfig.Instance.getDefaultLocalIP();
        LOCAL_IP = CommonMethods.ipStringToInt(ipAddress.Address);

        //builder.addDisallowedApplication("io.github.baoliandeng");

        builder.addAddress(ipAddress.Address, ipAddress.PrefixLength);
        if (ProxyConfig.IS_DEBUG)
            Log.d("BaoLianDeng", String.format("addAddress: %s/%d\n", ipAddress.Address, ipAddress.PrefixLength));

        for (ProxyConfig.IPAddress dns : ProxyConfig.Instance.getDnsList()) {
            builder.addDnsServer(dns.Address);
        }

        ProxyConfig.Instance.resetDomain(getResources().getStringArray(R.array.black_list));

        for (String routeAddress : getResources().getStringArray(R.array.bypass_private_route)) {
            String[] addr = routeAddress.split("/");
            builder.addRoute(addr[0], Integer.parseInt(addr[1]));
        }

        builder.addRoute(CommonMethods.ipIntToString(ProxyConfig.FAKE_NETWORK_IP), 16);

        Intent intent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, intent, 0);
        builder.setConfigureIntent(pendingIntent);

        builder.setSession(ProxyConfig.Instance.getSessionName());
        ParcelFileDescriptor pfdDescriptor = builder.establish();
        onStatusChanged(ProxyConfig.Instance.getSessionName() + " " + getString(R.string.vpn_connected_status), true);
        return pfdDescriptor;
    }

    public void disconnectVPN() {
        try {
            if (m_VPNInterface != null) {
                m_VPNInterface.close();
                m_VPNInterface = null;
            }
        } catch (Exception e) {
            // ignore
        }
        onStatusChanged(ProxyConfig.Instance.getSessionName() + " " + getString(R.string.vpn_disconnected_status), false);
        this.m_VPNOutputStream = null;
    }

    private synchronized void dispose() {
        disconnectVPN();

        // ֹͣTcpServer
        if (m_TcpProxyServer != null) {
            m_TcpProxyServer.stop();
            m_TcpProxyServer = null;
            writeLog("LocalTcpServer stopped.");
        }

        if (m_DnsProxy != null) {
            m_DnsProxy.stop();
            m_DnsProxy = null;
            writeLog("LocalDnsProxy stopped.");
        }

        try {
            Client.Stop();
        } catch (Exception e) {
            // Ignore
        }

        stopSelf();
        IsRunning = false;
        System.exit(0);
    }

    @Override
    public void onDestroy() {
        Log.d("BaoLianDeng", "VPNService(%s) destroyed: " + ID);
        if (m_VPNThread != null) {
            m_VPNThread.interrupt();
        }
    }

    public interface onStatusChangedListener {
        public void onStatusChanged(String status, Boolean isRunning);

        public void onLogReceived(String logString);
    }

}
