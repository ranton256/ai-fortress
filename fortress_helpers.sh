#!/bin/bash

# source this

alias fortress-ssh='ssh ranton@$(virsh -q -c qemu:///system domifaddr ai-fortress | awk "{print \$4}" | cut -d/ -f1)'

function agent() {
    # Get the VM IP automatically
    VM_IP=$(virsh -q -c qemu:///system domifaddr ai-fortress | awk '{print $4}' | cut -d/ -f1)

    # Run the agent over SSH with TTY support
    ssh -t ranton@$VM_IP \
      "OPENCODE_API_KEY=$OPENCODE_API_KEY ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY /opt/bin/agent-up $1"
}

