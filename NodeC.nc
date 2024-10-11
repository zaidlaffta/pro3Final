/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

typedef nx_struct RouteNode{
   nx_uint16_t dest;
   nx_uint16_t nextHop;
   nx_uint16_t cost;
} RouteNode;

typedef struct ConnectedClients{
   char *username;
   nx_uint16_t srcNode;
   nx_uint16_t srcPort;
   nx_uint16_t destPort;
   nx_uint16_t seqNum;
} ConnectedClients;

typedef struct ChatPackets{
   char *message;
   char *username;
   //char *receiver;
   uint8_t info;
   uint8_t srcPort;
   uint8_t destPort;
   uint8_t seqNum;

} ChatPackets;

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;

    Node.Receive -> GeneralReceive;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;

    components new TimerMilliC() as myTimerC;
    Node.periodicTimer -> myTimerC;

    components new TimerMilliC() as myTimerC1;
    Node.periodicTimer1 -> myTimerC1;
    
    components new TimerMilliC() as TCP_Timer;
    Node.TCP_Timer -> TCP_Timer;

    components new TimerMilliC() as TCP_Timeout;
    Node.TCP_Timeout -> TCP_Timeout;

    components new ListC(pack, 64) as ListPacketsC;
    Node.ListPackets -> ListPacketsC;

    components new ListC(char, 64) as NeighborListC;
    Node.NeighborList -> NeighborListC;

    components new ListC(RouteNode, 255) as RouteTableC;
    Node.RouteTable -> RouteTableC;

    components new ListC(ConnectedClients, 255) as ConnectedClientsC;
    Node.ClientsDB -> ConnectedClientsC;
}
