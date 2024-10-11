from TestSim import TestSim

def main():
    # connect testsim
    s = TestSim();

    # network off
    s.runTime(1);

    s.loadTopo("long_line.topo");
    s.loadNoise("no_noise.txt");

    # Sensor turn off
    s.bootAll();

    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);

    s.runTime(500);
    s.setAppServer(1,1);
    s.runTime(500);
    s.setAppClient(2,"hello shrithik 3\n");
    s.runTime(500);
    s.setAppClient(3,"hello dale 3\n");
    s.runTime(500);
    s.setAppClient(7,"hello hamid 3\n");
    s.runTime(500);
    s.setAppClient(2,"msg hello World!\n");
    s.runTime(500);
    s.setAppClient(7,"whisper dale hi!\n");
    s.runTime(500);
    s.setAppClient(2,"listusr\n");
    s.runTime(500);

if __name__ == '__main__':
    main()
