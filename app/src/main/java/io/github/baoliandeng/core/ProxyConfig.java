package io.github.baoliandeng.core;

import android.annotation.SuppressLint;
import android.util.Log;
import io.github.baoliandeng.BuildConfig;
import io.github.baoliandeng.tcpip.CommonMethods;
import io.github.baoliandeng.tunnel.Config;
import io.github.baoliandeng.tunnel.httpconnect.HttpConnectConfig;

import java.net.InetSocketAddress;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Locale;

public class ProxyConfig {
    public static final ProxyConfig Instance = new ProxyConfig();
    public final static boolean IS_DEBUG = BuildConfig.DEBUG;
    public final static int FAKE_NETWORK_MASK = CommonMethods.ipStringToInt("255.255.0.0");
    public final static int FAKE_NETWORK_IP = CommonMethods.ipStringToInt("26.25.0.0");
    public static String AppInstallID;
    public static String AppVersion;

    ArrayList<IPAddress> m_IpList;
    ArrayList<IPAddress> m_DnsList;
    ArrayList<Config> m_ProxyList;
    HashMap<String, Boolean> m_DomainMap;

    int m_dns_ttl = 10;
    String m_welcome_info = Constant.TAG;
    String m_session_name = Constant.TAG;
    String m_user_agent = System.getProperty("http.agent");
    int m_mtu = 1500;


    public ProxyConfig() {
        m_IpList = new ArrayList<IPAddress>();
        m_DnsList = new ArrayList<IPAddress>();
        m_ProxyList = new ArrayList<Config>();
        m_DomainMap = new HashMap<String, Boolean>();

        m_IpList.add(new IPAddress("26.26.26.2", 32));
        m_DnsList.add(new IPAddress("119.29.29.29"));
        m_DnsList.add(new IPAddress("223.5.5.5"));
        m_DnsList.add(new IPAddress("8.8.8.8"));

        Config config = HttpConnectConfig.parse("http://127.0.0.1:8787");
        if (!m_ProxyList.contains(config)) {
            m_ProxyList.add(config);
        }
    }

    public static boolean isFakeIP(int ip) {
        return (ip & ProxyConfig.FAKE_NETWORK_MASK) == ProxyConfig.FAKE_NETWORK_IP;
    }

    public Config getDefaultProxy() {
        return m_ProxyList.get(0);
    }

    public Config getDefaultTunnelConfig(InetSocketAddress destAddress) {
        return getDefaultProxy();
    }

    public IPAddress getDefaultLocalIP() {
        return m_IpList.get(0);
    }

    public ArrayList<IPAddress> getDnsList() {
        return m_DnsList;
    }

    public int getDnsTTL() {
        return m_dns_ttl;
    }

    public String getWelcomeInfo() {
        return m_welcome_info;
    }

    public String getSessionName() {
        return m_session_name;
    }

    public String getUserAgent() {
        return m_user_agent;
    }

    public int getMTU() {
        return m_mtu;
    }

    public void resetDomain(String[] items) {
        m_DomainMap.clear();
        addDomainToHashMap(items, 0, true);
    }

    private void addDomainToHashMap(String[] items, int offset, Boolean state) {
        for (int i = offset; i < items.length; i++) {
            String domainString = items[i].toLowerCase().trim();
            if (domainString.length() == 0) continue;
            if (domainString.charAt(0) == '.') {
                domainString = domainString.substring(1);
            }
            m_DomainMap.put(domainString, state);
        }
    }

    private Boolean getDomainState(String domain) {
        domain = domain.toLowerCase(Locale.ENGLISH);
        while (domain.length() > 0) {
            Boolean stateBoolean = m_DomainMap.get(domain);
            if (stateBoolean != null) {
                return stateBoolean;
            } else {
                int start = domain.indexOf('.') + 1;
                if (start > 0 && start < domain.length()) {
                    domain = domain.substring(start);
                } else {
                    return null;
                }
            }
        }
        return null;
    }

    public boolean needProxy(String host) {
        if (host != null) {
            Boolean stateBoolean = getDomainState(host);
            if (stateBoolean != null) {
                return stateBoolean.booleanValue();
            }

            try {
                if (!ChinaIpMaskManager.isIPInChina(host)) {
                    return true;
                }
            } catch (IllegalArgumentException ex) {
                // Ignore
            }
        }

        return false;
    }

    public boolean needProxy(int ip) {
        if (ip > 0) {
            if (isFakeIP(ip)) {
                return true;
            }

            if (!ChinaIpMaskManager.isIPInChina(ip)) {
                return true;
            }
        }

        return false;
    }


    public class IPAddress {
        public final String Address;
        public final int PrefixLength;

        public IPAddress(String address, int prefixLength) {
            this.Address = address;
            this.PrefixLength = prefixLength;
        }

        public IPAddress(String ipAddresString) {
            String[] arrStrings = ipAddresString.split("/");
            String address = arrStrings[0];
            int prefixLength = 32;
            if (arrStrings.length > 1) {
                prefixLength = Integer.parseInt(arrStrings[1]);
            }
            this.Address = address;
            this.PrefixLength = prefixLength;
        }

        @Override
        public String toString() {
            return String.format(Locale.ENGLISH, "%s/%d", Address, PrefixLength);
        }

        @Override
        public boolean equals(Object o) {
            if (o == null) {
                return false;
            } else {
                return this.toString().equals(o.toString());
            }
        }
    }

}
