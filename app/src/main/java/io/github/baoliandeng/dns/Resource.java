package io.github.baoliandeng.dns;

import java.nio.ByteBuffer;

public class Resource {
    public String Domain;
    public short Type;
    public short Class;
    public int TTL;
    public short DataLength;
    public byte[] Data;

    private int offset;
    private int length;

    public static Resource FromBytes(ByteBuffer buffer) {

        Resource r = new Resource();
        r.offset = buffer.arrayOffset() + buffer.position();
        r.Domain = DnsPacket.ReadDomain(buffer, buffer.arrayOffset());
        r.Type = buffer.getShort();
        r.Class = buffer.getShort();
        r.TTL = buffer.getInt();
        r.DataLength = buffer.getShort();
        r.Data = new byte[r.DataLength & 0xFFFF];
        buffer.get(r.Data);
        r.length = buffer.arrayOffset() + buffer.position() - r.offset;
        return r;
    }

    public int Offset() {
        return offset;
    }

    public int Length() {
        return length;
    }

    public void ToBytes(ByteBuffer buffer) {
        if (this.Data == null) {
            this.Data = new byte[0];
        }
        this.DataLength = (short) this.Data.length;

        this.offset = buffer.position();
        DnsPacket.WriteDomain(this.Domain, buffer);
        buffer.putShort(this.Type);
        buffer.putShort(this.Class);
        buffer.putInt(this.TTL);

        buffer.putShort(this.DataLength);
        buffer.put(this.Data);
        this.length = buffer.position() - this.offset;
    }


}
