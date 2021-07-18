#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Setup GUI on EC2 https://aws.amazon.com/premiumsupport/knowledge-center/ec2-linux-2-install-gui/
TARGET_USER=ubuntu
ROS_DISTRO=melodic
TARGET_HOME_DIR=/home/${TARGET_USER}
TARGET_CATKIN_DIR=${TARGET_HOME_DIR}/catkin_ws

# Will be set by CDK
INSTALL_SAMPLE_DATA=$CDK_PROJECT_CONFIG_INSTALL_SAMPLE_DATA
SSM_VNC_PASSWORD_PARAMETER_NAME=$CDK_PROJECT_CONFIG_VNC_PASSWORD_PARAMETER_NAME

# Add ROS package registry
# http://wiki.ros.org/melodic/Installation/Ubuntu#Installation.2BAC8-Ubuntu.2BAC8-Sources.Setup_your_sources.list
sh -c 'echo "deb http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" > /etc/apt/sources.list.d/ros-latest.list'
apt-key adv --keyserver 'hkp://keyserver.ubuntu.com:80' --recv-key C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654

# Dependencies
apt update &&
    apt install -y xserver-xorg-core \
        tigervnc-standalone-server \
        tigervnc-xorg-extension \
        tigervnc-viewer \
        ubuntu-gnome-desktop \
        fcitx-config-gtk \
        gnome-tweak-tool \
        gnome-usage \
        git-all \
        ros-${ROS_DISTRO}-roscpp \
        ros-${ROS_DISTRO}-rospy \
        ros-${ROS_DISTRO}-std-msgs \
        ros-${ROS_DISTRO}-sensor-msgs \
        ros-${ROS_DISTRO}-tf2-ros libpcl-dev \
        ros-${ROS_DISTRO}-pcl-conversions \
        ros-${ROS_DISTRO}-rviz-visual-tools \
        ros-${ROS_DISTRO}-velodyne
rm -rf /var/lib/apt/lists/*

# Setup AWS-CLI
cd /home/$TARGET_USER
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
$TARGET_HOME_DIR/aws/install
rm awscliv2.zip
chown -R "$TARGET_USER:$TARGET_USER" $TARGET_HOME_DIR/aws

# Add password to ubuntu
PASS=$(aws ssm get-parameters --output=text --names=$SSM_VNC_PASSWORD_PARAMETER_NAME --with-decryption --query=Parameters[0].Value)
echo $TARGET_USER:$PASS | chpasswd

# Setup VNC
# https://www.teknotut.com/en/install-vnc-server-with-gnome-display-on-ubuntu-18-04/
mkdir -p $TARGET_HOME_DIR/.vnc
echo "$PASS" | vncpasswd -f >$TARGET_HOME_DIR/.vnc/passwd

(
    cat <<-EOM
#!/bin/sh
vncconfig -iconic &
"$SHELL" -l << EOF
export XDG_SESSION_TYPE=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
dbus-launch --exit-with-session gnome-session --session=ubuntu
EOF
vncserver -kill $DISPLAY
EOM
) >$TARGET_HOME_DIR/.vnc/xstartup

(
    cat <<-EOM
geometry=1920x1080
depth=32
EOM
) >$TARGET_HOME_DIR/.vnc/config

echo "/usr/bin/vncserver -localhost no" >vnc_launch.sh
echo "/usr/bin/vncserver --kil :1" >vnc_kill.sh
touch .Xauthority

chmod +x $TARGET_HOME_DIR/vnc_launch.sh
chmod +x $TARGET_HOME_DIR/vnc_kill.sh
chmod +x $TARGET_HOME_DIR/.vnc/xstartup
chmod 0600 $TARGET_HOME_DIR/.vnc/passwd
chown -R "$TARGET_USER:$TARGET_USER" $TARGET_HOME_DIR/.vnc
chown "$TARGET_USER:$TARGET_USER" $TARGET_HOME_DIR/vnc_*.sh
chown "$TARGET_USER:$TARGET_USER" $TARGET_HOME_DIR/.Xauthority

# Startup VNC on boot
# https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-vnc-on-ubuntu-18-04
# https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/3038
# https://www.teknotut.com/en/install-vnc-server-with-gnome-display-on-ubuntu-18-04/

(
    cat <<-EOF
[Unit]
Description=TigerVNC Service
After=syslog.target network.target

[Service]
Type=simple
RemainAfterExit=yes
SuccessExitStatus=0
User=${TARGET_USER}
PIDFile=/home/${TARGET_USER}/.vnc/%H:%i.pid
ExecStartPre=/usr/bin/vncserver -kill :%i > /dev/null
ExecStart=/usr/bin/vncserver -localhost yes :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=default.target
EOF
) >/etc/systemd/system/vncserver@.service

systemctl daemon-reload
systemctl enable vncserver@1
systemctl start vncserver@1

# To see the status of the user-data script you can
# ssh into the machine and run tail -f /var/log/cloud-init-output.log

if [ "$INSTALL_SAMPLE_DATA" = true ]; then
    echo "INSTALL_SAMPLE_DATA=$INSTALL_SAMPLE_DATA. Installing sample data..."
    # ROS Tooling
    # http://wiki.ros.org/catkin/Tutorials/create_a_workspace
    source /opt/ros/${ROS_DISTRO}/setup.sh
    mkdir -p $TARGET_CATKIN_DIR/src
    chown -R "$TARGET_USER:$TARGET_USER" $TARGET_CATKIN_DIR
    cd $TARGET_CATKIN_DIR
    catkin_make
    source devel/setup.sh
    echo $ROS_PACKAGE_PAT

    # Ford AV Sample Data
    # https://github.com/Ford/AVData
    cd $TARGET_CATKIN_DIR/src
    git clone https://github.com/Ford/AVData.git
    cd $TARGET_CATKIN_DIR
    catkin_make
    source devel/setup.sh
    curl -O https://ford-multi-av-seasonal.s3-us-west-2.amazonaws.com/Sample-Data.tar.gz
    mkdir sample
    tar -xzvf Sample-Data.tar.gz -C ./sample/

    (
        cat <<-EOM
#!/bin/bash
source /opt/ros/melodic/setup.sh
source devel/setup.sh
roslaunch ford_demo demo.launch map_dir:=$TARGET_CATKIN_DIR/sample/Map/ calibration_dir:=$TARGET_CATKIN_DIR/sample/Calibration-V2/
EOM
    ) >1-launch.sh

    (
        cat <<-EOM
#!/bin/bash
source /opt/ros/melodic/setup.sh
source devel/setup.sh
roslaunch ford_demo multi_lidar_convert.launch
EOM
    ) >2-view-pc.sh

    (
        cat <<-EOM
#!/bin/bash
source /opt/ros/melodic/setup.sh
rosbag play -l $TARGET_CATKIN_DIR/sample/Sample-Data.bag
EOM
    ) >3-play.sh

    chmod +x 1-launch.sh
    chmod +x 2-view-pc.sh
    chmod +x 3-play.sh

    (
        cat <<-EOM
#!/bin/bash
echo "Launching"
gnome-terminal --tab -- ./1-launch.sh
sleep 5
echo "View Point Cloud"
gnome-terminal --tab -- ./2-view-pc.sh
sleep 5
echo "Play Rosbag"
gnome-terminal --tab -- ./3-play.sh
echo "To replay the rosbag, go to the third tab and rerun ./3-play.sh"
EOM
    ) >0-run-all.sh

    chmod +x 0-run-all.sh

fi

chown -R "$TARGET_USER:$TARGET_USER" $TARGET_CATKIN_DIR

echo "rviz-setup bootstrapping completed. You can now log in via VNC"