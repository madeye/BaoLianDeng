package io.github.baoliandeng.dns;

public class DnsFlags {
    public boolean QR;//1 bits
    public int OpCode;//4 bits
    public boolean AA;//1 bits
    public boolean TC;//1 bits
    public boolean RD;//1 bits
    public boolean RA;//1 bits
    public int Zero;//3 bits
    public int Rcode;//4 bits

    public static DnsFlags Parse(short value) {
        int m_Flags = value & 0xFFFF;
        DnsFlags flags = new DnsFlags();
        flags.QR = ((m_Flags >> 7) & 0x01) == 1;
        flags.OpCode = (m_Flags >> 3) & 0x0F;
        flags.AA = ((m_Flags >> 2) & 0x01) == 1;
        flags.TC = ((m_Flags >> 1) & 0x01) == 1;
        flags.RD = (m_Flags & 0x01) == 1;
        flags.RA = (m_Flags >> 15) == 1;
        flags.Zero = (m_Flags >> 12) & 0x07;
        flags.Rcode = ((m_Flags >> 8) & 0xF);
        return flags;
    }

    public short ToShort() {
        int m_Flags = 0;
        m_Flags |= (this.QR ? 1 : 0) << 7;
        m_Flags |= (this.OpCode & 0x0F) << 3;
        m_Flags |= (this.AA ? 1 : 0) << 2;
        m_Flags |= (this.TC ? 1 : 0) << 1;
        m_Flags |= this.RD ? 1 : 0;
        m_Flags |= (this.RA ? 1 : 0) << 15;
        m_Flags |= (this.Zero & 0x07) << 12;
        m_Flags |= (this.Rcode & 0x0F) << 8;
        return (short) m_Flags;
    }
}
