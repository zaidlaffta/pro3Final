#include "../../includes/channels.h"
#include "../../includes/protocol.h"
#include "../../includes/packet.h"

module FloodingP{
	provides interface SimpleSend as FloodSender;
	provides interface Receive as MainReceive;
	uses interface SimpleSend as InternalSender;
	uses interface Receive as InternalReceiver;
}
implementation {

	typedef struct histentry{
		uint16_t src;
		uint16_t seq;
	};

	uint16_t seq = 0;
	uint16_t counter = 0;
	struct histentry History[30];

	bool isInHistory(uint16_t theSrc, uint16_t theSeq){
		uint32_t i;
		for (i = 0; i < 30; i++) {
			if (theSrc == History[i].src && theSeq == History[i].seq) {
				return TRUE;
			}
		}
		return FALSE;
	}

	void addToHistory(uint16_t theSrc, uint16_t theSeq) {
		if (counter < 30) {
			History[counter].src = theSrc;
			History[counter].seq = theSeq;
			counter++;
		} else {
			uint32_t i;
			for (i = 0; i<(30-1); i++) {
				History[i].src = History[i+1].src;
				History[i].seq = History[i+1].seq;
			}
			History[30].src = theSrc;
			History[30].seq = theSeq;
		}
		return;
	}

	command error_t FloodSender.send(pack msg, uint16_t dest){
		msg.src = TOS_NODE_ID;
		msg.TTL = MAX_TTL;

		msg.seq = seq++;
		call InternalSender.send(msg, AM_BROADCAST_ADDR);
	}

	event message_t* InternalReceiver.receive(message_t* raw_msg, void* payload, uint8_t len){
		pack *msg = (pack *) payload;
		if (isInHistory(msg->src,msg->seq)) {
			return raw_msg;
		}		
		addToHistory(msg->src, msg->seq);
		if (msg->dest == TOS_NODE_ID) {
			if (msg->protocol == PROTOCOL_PING) {
				uint16_t temp = msg->src;
				msg->src = msg->dest;
				msg->dest = temp;
				msg->protocol = PROTOCOL_PINGREPLY;
				dbg(FLOODING_CHANNEL, "Send Ping response to: %u \n", msg->dest); 
				call FloodSender.send(*msg, msg->dest);
				return signal MainReceive.receive(raw_msg, payload, len);
			} else {
				dbg(FLOODING_CHANNEL, "Final response: %u \n", msg->src);
			}
		} else { 
			msg->TTL--;
			if (msg->TTL == 0) {		
                                //dbg(FLOODING_CHANNEL, "TTL Run out: %s \n", msg->payload);
				return raw_msg;		
			}
			call InternalSender.send(*msg, AM_BROADCAST_ADDR);
		} 

		
		return raw_msg;
	}
}

