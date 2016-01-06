package io.github.baoliandeng.core;

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.BufferedReader;

import io.github.baoliandeng.tcpip.CommonMethods;
import net.ripe.commons.ip.SortedResourceSet;
import net.ripe.commons.ip.Ipv4Range;
import net.ripe.commons.ip.Ipv4;

public class ChinaIpMaskManager {

    static SortedResourceSet<Ipv4, Ipv4Range> set = new SortedResourceSet<Ipv4, Ipv4Range>();

    public static boolean isIPInChina(int ip){
        Ipv4 ipv4 = Ipv4.of(Long.valueOf(ip));
        return set.contains(ipv4);
    }

    public static void loadFromFile(InputStream inputStream){
        try {
            BufferedReader br = new BufferedReader(new InputStreamReader(inputStream));
            String line;
            while ((line = br.readLine()) != null) {
                set.add(Ipv4Range.parse(line.trim()));
            }
            inputStream.close();
        } catch (IOException e) {
            // Ignore
        }
    }
}
