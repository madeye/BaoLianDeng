package io.github.baoliandeng.core;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.SharedPreferences.Editor;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import lantern.*;

import io.github.baoliandeng.R;
import io.github.baoliandeng.core.ProxyConfig.IPAddress;
import io.github.baoliandeng.dns.DnsPacket;
import io.github.baoliandeng.tcpip.CommonMethods;
import io.github.baoliandeng.tcpip.IPHeader;
import io.github.baoliandeng.tcpip.TCPHeader;
import io.github.baoliandeng.tcpip.UDPHeader;
import io.github.baoliandeng.ui.MainActivity;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

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
    private String[] m_Blacklist;

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
        writeLog("This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.");
        writeLog("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.");

        writeLog("This program includes two other open source programs:");
        writeLog("SmartProxy Copyright (C) 2014 hedaode. GPLv3");
        writeLog("Lantern Copyright 2010 Brave New Software Project, Inc. Apache 2.0");

        try {
            m_TcpProxyServer = new TcpProxyServer(0);
            m_TcpProxyServer.start();
            writeLog("LocalTcpServer started.");

            m_DnsProxy = new DnsProxy();
            m_DnsProxy.start();
            writeLog("LocalDnsProxy started.");
        } catch (Exception e) {
            writeLog("Failed to start TCP/DNS Proxy");
        }

        super.onCreate();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        super.onStartCommand(intent, flags, startId);
        IsRunning = true;
        // Start a new session by creating a new thread.
        m_VPNThread = new Thread(this, "VPNServiceThread");
        m_VPNThread.start();
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        String action = intent.getAction();
        if (action.equals(VpnService.SERVICE_INTERFACE)) {
            return super.onBind(intent);
        }
        return null;
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
        SharedPreferences preferences = getSharedPreferences(Constant.TAG, MODE_PRIVATE);
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

    public String configDirFor(Context context, String suffix) {
        return new File(context.getFilesDir().getAbsolutePath(), ".lantern" + suffix).getAbsolutePath();
    }

    @Override
    public synchronized void run() {
        try {
            Log.d(Constant.TAG, "VPNService work thread is running... " + ID);

            ProxyConfig.AppInstallID = getAppInstallID();
            ProxyConfig.AppVersion = getVersionName();
            writeLog("Android version: %s", Build.VERSION.RELEASE);
            writeLog("App version: %s", ProxyConfig.AppVersion);

            waitUntilPrepared();

            Lantern.protectConnections("119.29.29.29", new SocketProtector() {
                // Protect is used to exclude a socket specified by fileDescriptor
                // from the VPN connection. Once protected, the underlying connection
                // is bound to the VPN device and won't be forwarded
                @Override
                public void protect(long fileDescriptor) throws Exception {
                    if (!LocalVpnService.this.protect((int) fileDescriptor)) {
                        throw new Exception("protect socket failed");
                    }
                }
            });

            StartResult result =
                Lantern.start(configDirFor(this, ""), 10000, ProxyConfig.IS_DEBUG);

            ProxyConfig.Instance.addProxy("http://" + result.getHTTPAddr());

            ChinaIpMaskManager.loadFromFile(getResources().openRawResource(R.raw.ipmask));

            OkHttpClient client = new OkHttpClient();
            Request request = new Request.Builder()
                    .url("https://myhosts.sinaapp.com/blacklist.txt")
                    .build();

            try {
                Response response = client.newCall(request).execute();
                String body = response.body().string();
                m_Blacklist = body.split("\\r?\\n");
            } catch (IOException e) {
                Log.e(Constant.TAG, "Unable to fetch blacklist");
            }

            runVPN();

        } catch (InterruptedException e) {
            Log.e(Constant.TAG, "Exception", e);
        } catch (Exception e) {
            e.printStackTrace();
            writeLog("Fatal error: %s", e.toString());
        }

        writeLog("BaoLianDeng terminated.");
        dispose();
    }

    private void runVPN() throws Exception {
        this.m_VPNInterface = establishVPN();
        this.m_VPNOutputStream = new FileOutputStream(m_VPNInterface.getFileDescriptor());
        FileInputStream in = new FileInputStream(m_VPNInterface.getFileDescriptor());
        try {
            while (IsRunning) {
                boolean idle = true;
                int size = in.read(m_Packet);
                if (size > 0) {
                    if (m_DnsProxy.Stopped || m_TcpProxyServer.Stopped) {
                        in.close();
                        throw new Exception("LocalServer stopped.");
                    }
                    try {
                        onIPPacketReceived(m_IPHeader, size);
                        idle = false;
                    } catch (IOException ex) {
                        Log.e(Constant.TAG, "IOException when processing IP packet", ex);
                    }
                }
                if (idle) {
                    Thread.sleep(100);
                }
            }
        } finally {
            in.close();
        }
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
                                Log.d(Constant.TAG, "NoSession: " +
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

    private void waitUntilPrepared() {
        while (prepare(this) != null) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                // Ignore
            }
        }
    }

    private ParcelFileDescriptor establishVPN() throws Exception {

        NatSessionManager.clearAllSessions();

        Builder builder = new Builder();
        builder.setMtu(ProxyConfig.Instance.getMTU());

        IPAddress ipAddress = ProxyConfig.Instance.getDefaultLocalIP();
        LOCAL_IP = CommonMethods.ipStringToInt(ipAddress.Address);

        builder.addAddress(ipAddress.Address, ipAddress.PrefixLength);
        if (ProxyConfig.IS_DEBUG)
            Log.d(Constant.TAG, String.format("addAddress: %s/%d\n", ipAddress.Address, ipAddress.PrefixLength));

        for (ProxyConfig.IPAddress dns : ProxyConfig.Instance.getDnsList()) {
            builder.addDnsServer(dns.Address);
        }

        if (m_Blacklist == null) {
            m_Blacklist = getResources().getStringArray(R.array.black_list);
        }

        ProxyConfig.Instance.resetDomain(m_Blacklist);

        for (String routeAddress : getResources().getStringArray(R.array.bypass_private_route)) {
            String[] addr = routeAddress.split("/");
            builder.addRoute(addr[0], Integer.parseInt(addr[1]));
        }

        builder.addRoute(CommonMethods.ipIntToString(ProxyConfig.FAKE_NETWORK_IP), 16);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            PackageManager packageManager = getPackageManager();
            List<PackageInfo> list = packageManager.getInstalledPackages(0);
            HashSet<String> packageSet = new HashSet<>();

            for (int i = 0; i < list.size(); i++) {
                PackageInfo info = list.get(i);
                packageSet.add(info.packageName);
            }

            for (String name : getResources().getStringArray(R.array.bypass_package_name)) {
                if (packageSet.contains(name)) {
                    builder.addDisallowedApplication(name);
                }
            }
        }

        Intent intent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, intent, 0);
        builder.setConfigureIntent(pendingIntent);

        builder.setSession(ProxyConfig.Instance.getSessionName());
        ParcelFileDescriptor pfdDescriptor = builder.establish();
        onStatusChanged(ProxyConfig.Instance.getSessionName() + " " + getString(R.string.vpn_connected_status), true);
        return pfdDescriptor;
    }

    private synchronized void dispose() {

        onStatusChanged(ProxyConfig.Instance.getSessionName() + " " + getString(R.string.vpn_disconnected_status), false);

        IsRunning = false;

        try {
            if (m_VPNInterface != null) {
                m_VPNInterface.close();
                m_VPNInterface = null;
            }
        } catch (Exception e) {
            // ignore
        }

        try {
            if (m_VPNOutputStream != null) {
                m_VPNOutputStream.close();
                m_VPNOutputStream = null;
            }
        } catch (Exception e) {
            // ignore
        }

        try {
            Lantern.removeOverrides();
        } catch (Exception e) {
            // Ignore
        }

        if (m_VPNThread != null) {
            m_VPNThread.interrupt();
            m_VPNThread = null;
        }
    }

    @Override
    public void onDestroy() {
        Log.d(Constant.TAG, "VPNService(%s) destroyed: " + ID);
        if(IsRunning) dispose();
        try {
            // ֹͣTcpServer
            if (m_TcpProxyServer != null) {
                m_TcpProxyServer.stop();
                m_TcpProxyServer = null;
                // writeLog("LocalTcpServer stopped.");
            }
        } catch (Exception e) {
            // ignore
        }
        try {
            // DnsProxy
            if (m_DnsProxy != null) {
                m_DnsProxy.stop();
                m_DnsProxy = null;
                // writeLog("LocalDnsProxy stopped.");
            }
        } catch (Exception e) {
            // ignore
        }
        super.onDestroy();
    }

    public interface onStatusChangedListener {
        void onStatusChanged(String status, Boolean isRunning);
        void onLogReceived(String logString);
    }

}
