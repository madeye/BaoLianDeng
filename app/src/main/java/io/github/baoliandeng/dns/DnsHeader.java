package io.github.baoliandeng.dns;

import io.github.baoliandeng.tcpip.CommonMethods;

import java.nio.ByteBuffer;


public class DnsHeader {
    static final short offset_ID = 0;
    static final short offset_Flags = 2;
    static final short offset_QuestionCount = 4;
    static final short offset_ResourceCount = 6;
    static final short offset_AResourceCount = 8;
    static final short offset_EResourceCount = 10;
    public short ID;
    public DnsFlags Flags;
    public short QuestionCount;
    public short ResourceCount;
    public short AResourceCount;
    public short EResourceCount;
    public byte[] Data;
    public int Offset;

    public DnsHeader(byte[] data, int offset) {
        this.Offset = offset;
        this.Data = data;
    }

    public static DnsHeader FromBytes(ByteBuffer buffer) {
        DnsHeader header = new DnsHeader(buffer.array(), buffer.arrayOffset() + buffer.position());
        header.ID = buffer.getShort();
        header.Flags = DnsFlags.Parse(buffer.getShort());
        header.QuestionCount = buffer.getShort();
        header.ResourceCount = buffer.getShort();
        header.AResourceCount = buffer.getShort();
        header.EResourceCount = buffer.getShort();
        return header;
    }

    public void ToBytes(ByteBuffer buffer) {
        buffer.putShort(this.ID);
        buffer.putShort(this.Flags.ToShort());
        buffer.putShort(this.QuestionCount);
        buffer.putShort(this.ResourceCount);
        buffer.putShort(this.AResourceCount);
        buffer.putShort(this.EResourceCount);
    }

    public short getID() {
        return CommonMethods.readShort(Data, Offset + offset_ID);
    }

    public void setID(short value) {
        CommonMethods.writeShort(Data, Offset + offset_ID, value);
    }

    public short getFlags() {
        return CommonMethods.readShort(Data, Offset + offset_Flags);
    }

    public void setFlags(short value) {
        CommonMethods.writeShort(Data, Offset + offset_Flags, value);
    }

    public short getQuestionCount() {
        return CommonMethods.readShort(Data, Offset + offset_QuestionCount);
    }

    public void setQuestionCount(short value) {
        CommonMethods.writeShort(Data, Offset + offset_QuestionCount, value);
    }

    public short getResourceCount() {
        return CommonMethods.readShort(Data, Offset + offset_ResourceCount);
    }

    public void setResourceCount(short value) {
        CommonMethods.writeShort(Data, Offset + offset_ResourceCount, value);
    }

    public short getAResourceCount() {
        return CommonMethods.readShort(Data, Offset + offset_AResourceCount);
    }

    public void setAResourceCount(short value) {
        CommonMethods.writeShort(Data, Offset + offset_AResourceCount, value);
    }

    public short getEResourceCount() {
        return CommonMethods.readShort(Data, Offset + offset_EResourceCount);
    }

    public void setEResourceCount(short value) {
        CommonMethods.writeShort(Data, Offset + offset_EResourceCount, value);
    }
}
